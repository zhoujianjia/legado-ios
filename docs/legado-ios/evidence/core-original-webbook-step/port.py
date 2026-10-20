from pathlib import Path
import re,zipfile
root=Path('Packages/LegadoRuntime/jvm/src/main/kotlin')
ref=Path('.build/original-webbook-execution/original-reference')
def write(path,text):
    p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text,encoding='utf-8',newline='\n')
def read(path):return (ref/path).read_text(encoding='utf-8')
# DTO fields/getters/toString are retained; Android Parcelable and Gson's Android
# INITIAL_GSON adapter registration are replaced by the explicit source decoder.
for name in ['BookListRule','SearchRule','ExploreRule','BookInfoRule','TocRule','ContentRule']:
    s=read(f'data/entities/rule/{name}.kt')
    s=re.sub(r'^import .*\n','',s,flags=re.M).replace('@Parcelize\n','').replace(', Parcelable','').replace(' : Parcelable','')
    start=s.find('    companion object {')
    if start>=0:s=s[:start]+'}\n'
    write(Path(f'io/legado/app/data/entities/rule/{name}.kt'), '// Retained original rule DTO, Android parceling removed. See vendor manifest.\n'+s)
s=read('data/entities/SearchBook.kt')
start=s.index('data class SearchBook(')
s='package io.legado.app.data.entities\n\nimport io.yuedu.legado.originalrule.*\n\n/** Retained SearchBook fields/conversion; transient environment storage, no Room/UI. */\n'+s[start:]
s=s.replace('data class SearchBook(','data class SearchBook(\n    @Transient internal val environment: RuleEnvironment,')
s=re.sub(r'^\s*@(?:PrimaryKey|Ignore|IgnoredOnParcel|delegate:Ignore|delegate:Transient|ColumnInfo[^\n]*)\n','\n',s,flags=re.M)
s=s.replace('BookType.text','8').replace('BookType.allBookTypeLocal','(4 or 8 or 32 or 64 or 128 or 256)').replace(': Parcelable, BaseBook',': BaseBook')
a=s.index('    fun trimIntro(');b=s.index('    fun releaseHtmlData()',a);s=s[:a]+s[b:]
s=s.replace('fun toBook() = Book(','fun toBook() = Book(\n        environment = environment,')
s=s.replace('    fun addOrigin(origin: String)', '    override fun putBigVariable(key: String, value: String?) = environment.state.putBook(bookUrl, key, value)\n    override fun getBigVariable(key: String): String? = environment.state.getBook(bookUrl, key)\n\n    fun addOrigin(origin: String)')
write(Path('io/legado/app/data/entities/SearchBook.kt'),s)
# Pure formatter copied with only utility import relocation.
s=read('utils/HtmlFormatter.kt').replace('import io.legado.app.model.analyzeRule.AnalyzeUrl','import io.legado.app.model.analyzeRule.AnalyzeUrl\nimport io.yuedu.legado.originalrule.NetworkUtils')
write(Path('io/legado/app/utils/HtmlFormatter.kt'),s)

def common(s):
    # Keep algorithmic bodies; relocate only explicit platform dependencies.
    s=re.sub(r'^import (?:android\.|splitties\.|io\.legado\.app\.(?:R$|exception\.|help\.|model\.Debug|constant\.AppPattern|data\.appDb|utils\.(?:GSON|GSONStrict|NetworkUtils|DebugLog|StringUtils|isTrue|mapAsync|fromJsonArray))).*\n','',s,flags=re.M)
    s=s.replace('package io.legado.app.model.webBook\n','package io.legado.app.model.webBook\n\nimport io.yuedu.legado.originalrule.*\nimport io.legado.app.utils.mapAsync\n')
    s=re.sub(r'appCtx.getString\(\s*R.string.error_get_web_content,\s*([^\n)]+)\s*\)',r'"获取网页内容失败: ${\1}"',s)
    s=s.replace('appCtx.getString(R.string.chapter_list_empty)','"目录列表为空"')
    s=s.replace('Book(variable = variable)','Book(bookSource.environment, variable = variable)').replace('SearchBook(variable = variable)','SearchBook(bookSource.environment, variable = variable)')
    s=s.replace('BookChapter(bookUrl = book.bookUrl, baseUrl = redirectUrl)','BookChapter(bookSource.environment, bookUrl = book.bookUrl, baseUrl = redirectUrl)')
    s=s.replace('coroutineContext = currentCoroutineContext()', 'environment = bookSource.environment,\n                    coroutineContext = currentCoroutineContext()')
    s=s.replace('AppConfig.threadCount','bookSource.environment.webBook.threadCount').replace('AppConfig.tocCountWords','book.environment.webBook.tocCountWords').replace('AppConfig.adaptSpecialStyle','book.environment.webBook.adaptSpecialStyle')
    s=re.sub(r'\bres\.(url|body|raw)\b(?!\()',r'res.\1()',s)
    s=s.replace('TextUtils.join("，\\n", nextUrlList)','nextUrlList.joinToString("，\\n")')
    # Ported catch blocks must not turn control failures into optional fields.
    s=s.replace('catch (e: Exception) {','catch (e: Exception) {\n            rethrowRuleControlFailure(e)')
    return s

s=common(read('model/webBook/BookList.kt'))
s=s.replace('import io.legado.app.data.entities.rule.ExploreKind\n','')
s=s.replace('        if (!isSearch) {\n            checkExploreJson(bookSource)\n        }\n','')
start=s.index('    private fun checkExploreJson(');s=s[:start]+'}\n'
write(Path('io/legado/app/model/webBook/BookList.kt'), '// Retained original orchestration; Android debug/explore UI check omitted.\n'+s)

s=common(read('model/webBook/BookInfo.kt'))
start=s.index('        if (!book.isWebFile) {');else_start=s.index('        } else {',start)
s=s[:start]+s[start:else_start].replace('        if (!book.isWebFile) {','        if (bookSource.bookSourceType != 3) {')+'        } else {\n            unsupportedRule("original WebBook file download sources")\n        }\n    }\n}\n'
write(Path('io/legado/app/model/webBook/BookInfo.kt'), '// Retained original detail parser; file downloads are explicitly unsupported.\n'+s)

s=common(read('model/webBook/BookChapterList.kt'))
a=s.index('        val replaceRules = ContentProcessor');b=s.index('        if (book.totalChapterNum < list.size)',a)
s=s[:a]+'''        // No Android title replacement configuration is inferred. This transient
        // contract preserves raw chapter titles and the original metadata order.
        book.durChapterTitle = list.getOrElse(book.durChapterIndex) { list.last() }.title
'''+s[b:]
a=s.index('        book.latestChapterTitle =');b=s.index('        currentCoroutineContext().ensureActive()',a)
s=s[:a]+'''        book.latestChapterTitle = list.getOrElse(book.totalChapterNum - 1) { list.last() }.title
'''+s[b:]
s=s.replace('        upChapterInfo(list, book)','        upChapterInfo(list, book)\n        book.environment.webBook.publish(book.bookUrl, list)')
s=s.replace('appDb.bookChapterDao.getChapterList(book.bookUrl)','book.environment.webBook.chapters(book.bookUrl)')
# Formatting title JS keeps one binding set (gInt), but now uses existing guarded
# Rhino binding/context plumbing instead of entering a bare Android context.
s=s.replace('Context.enter().use {','run {').replace('eval(formatJs, bindings)', 'eval(formatJs, bindings, currentCoroutineContext())')
s=s.replace('}.onFailure {\n                        Debug.log', '}.onFailure {\n                        if (it is Exception) rethrowRuleControlFailure(it)\n                        currentCoroutineContext().ensureActive()\n                        Debug.log')
s=s.replace('import org.htmlunit.corejs.javascript.Context\n','')
write(Path('io/legado/app/model/webBook/BookChapterList.kt'), '// Retained original pagination, ordering, deduplication and field extraction.\n// Room lookup is explicitly transient environment chapter state; title replacement UI is unported.\n'+s)

s=common(read('model/webBook/BookContent.kt'))
s=s[:s.index('    /**\n     * 批量获取正文。')]+'}\n'
s=s.replace('import io.legado.app.model.BatchContentContext\n','').replace('import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setBatchContext\n','')
s=s.replace('appDb.bookChapterDao.getChapter(book.bookUrl, bookChapter.index + 1)?.url','book.environment.webBook.chapters(book.bookUrl).firstOrNull { it.index == bookChapter.index + 1 }?.url').replace('appDb.bookChapterDao.getChapter(book.bookUrl, 0)?.url','book.environment.webBook.chapters(book.bookUrl).firstOrNull { it.index == 0 }?.url')
a=s.index('        val subContentRule =');b=s.index('        var contentStr =',a)
s=s[:a]+'''        if (!contentRule.subContent.isNullOrBlank()) unsupportedRule("original WebBook subContent/media side channels")
'''+s[b:]
s=s.replace('            if (book.isOnLineTxt) {\n                contentStr = contentStr.split(AppPattern.LFRegex).joinToString("\\n") { "　　$it" }\n            }\n','')
s=s.replace('if (!book.isAudio && !book.isVideo)', 'if (bookSource.bookSourceType == 0)')
a=s.index('        if (needSave) {');b=s.index('        return contentStr',a)
s=s[:a]+'        if (needSave) unsupportedRule("original WebBook persistent content cache")\n'+s[b:]
# Reject unavailable saving/side channels before issuing any page request.
needle='    ): String {\n'
s=s.replace(needle,needle+'        if (needSave) unsupportedRule("original WebBook persistent content cache")\n',1)
s=s.replace('}.onFailure {\n                Debug.log', '}.onFailure {\n                if (it is Exception) rethrowRuleControlFailure(it)\n                currentCoroutineContext().ensureActive()\n                Debug.log')
write(Path('io/legado/app/model/webBook/BookContent.kt'), '// Retained original single/multiple-page content algorithm; transient no-save text contract only.\n'+s)

# Retain the upstream ordered concurrent map implementation, not a new paginator.
s=read('utils/FlowExtensions.kt');a=s.index('inline fun <T, R> Flow<T>.mapAsync(');b=s.index('inline fun <T, R> Flow<T>.mapAsyncIndexed(',a)
write(Path('io/legado/app/utils/OriginalMapAsync.kt'), 'package io.legado.app.utils\n\nimport kotlinx.coroutines.async\nimport kotlinx.coroutines.flow.*\nimport kotlinx.coroutines.sync.Semaphore\n\n// Retained locked-ZIP FlowExtensions.mapAsync, preserving emission order.\n'+s[a:b])

def function(text,name):
    start=text.index('    suspend fun '+name+'(')
    body=text.index('{', start);i=body;depth=0;quote=None;line=False;block=False
    while i<len(text):
        ch=text[i];n=text[i:i+2]
        if line:
            if ch=='\n':line=False
        elif block:
            if n=='*/':block=False;i+=1
        elif quote:
            if ch=='\\':i+=1
            elif ch==quote:quote=None
        elif n=='//':line=True;i+=1
        elif n=='/*':block=True;i+=1
        elif ch in ['"',"'"]:quote=ch
        elif ch=='{':depth+=1
        elif ch=='}':
            depth-=1
            if depth==0:return text[start:i+1]
        i+=1
    raise Exception(name)
original=read('model/webBook/WebBook.kt')
names=['searchBookAwait','getBookInfoAwait','runPreUpdateJs','getChapterListAwait','getContentAwait','preciseSearchAwait']
parts=[]
for name in names:
    s=function(original,name)
    if name=='getContentAwait':
        a=s.index('        val saveToken =');b=s.index('        if (bookChapter.isVolume',a)
        s=s[:a]+'''        if (needSave) unsupportedRule("original WebBook persistent content cache")
'''+s[b:]
        a=s.index('        if (saveToken != null)');b=s.index('        return content',a);s=s[:a]+s[b:]
    else:
        s=re.sub(r'        if \(bookSource.isJsSource\(\)\) \{\n.*?\n        }\n','',s,flags=re.S)
    s=s.replace('= withContext(SuppressSourceNavigation) {','= run {')
    s=s.replace('AppLog.put("执行preUpdateJs规则失败 书源:${bookSource.bookSourceName}", it)','if (it is Exception) rethrowRuleControlFailure(it)\n            Debug.log(bookSource.bookSourceUrl, "执行preUpdateJs规则失败: $it")')
    # Ordinary loginCheck recovery remains upstream; task/capability control never
    # becomes a fabricated HTTP error response or is swallowed by login scripts.
    s=s.replace('}.getOrElse { throwable ->','}.getOrElse { throwable ->\n            if (throwable is Exception) rethrowRuleControlFailure(throwable)\n            currentCoroutineContext().ensureActive()')
    s=s.replace('}.onFailure {\n            currentCoroutineContext().ensureActive()','}.onFailure {\n            if (it is Exception) rethrowRuleControlFailure(it)\n            currentCoroutineContext().ensureActive()')
    s=s.replace('suspend fun '+name+'(', 'private suspend fun '+name+'Owned(')
    parts.append(s)
s='''package io.legado.app.model.webBook

import io.legado.app.data.entities.*
import io.legado.app.model.analyzeRule.*
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.yuedu.legado.originalrule.*
import io.yuedu.legado.StrResponse
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Retained WebBook await orchestration through the single task-owned JVM HTTP.
 * Android launch/UI wrappers, durable saving, mainJs, media, file downloads,
 * explore UI navigation/infoMap and contentBatch remain explicit unsupported.
 * This class name does not imply the full Android WebBook ABI or App routing.
 */
object WebBook {
    private suspend fun <T> owned(source: BookSource, book: Book? = null, chapter: BookChapter? = null, action: suspend () -> T): T {
        val environment = source.environment
        check(book == null || book.environment === environment) { "Book belongs to another original environment" }
        check(chapter == null || chapter.environment === environment) { "Chapter belongs to another original environment" }
        if (source.isJsSource()) unsupportedRule("WebBook mainJs uses the separate retained JsSourceBook route")
        if (source.bookSourceType != 0) unsupportedRule("original WebBook media/file source type")
        return environment.platform.runWebBook(currentCoroutineContext(), action)
    }
    suspend fun searchBookAwait(bookSource: BookSource, key: String, page: Int? = 1,
        filter: ((String, String, String?) -> Boolean)? = null, shouldBreak: ((Int) -> Boolean)? = null): ArrayList<SearchBook> =
        owned(bookSource) { searchBookAwaitOwned(bookSource, key, page, filter, shouldBreak) }
    suspend fun getBookInfoAwait(bookSource: BookSource, book: Book, canReName: Boolean = true): Book =
        owned(bookSource, book) { getBookInfoAwaitOwned(bookSource, book, canReName) }
    suspend fun runPreUpdateJs(bookSource: BookSource, book: Book, isFromBookInfo: Boolean = false): Result<Unit> =
        owned(bookSource, book) { runPreUpdateJsOwned(bookSource, book, isFromBookInfo) }
    suspend fun getChapterListAwait(bookSource: BookSource, book: Book, runPerJs: Boolean = false, isFromBookInfo: Boolean = false): Result<List<BookChapter>> =
        owned(bookSource, book) { getChapterListAwaitOwned(bookSource, book, runPerJs, isFromBookInfo) }
    suspend fun getContentAwait(bookSource: BookSource, book: Book, bookChapter: BookChapter, nextChapterUrl: String? = null, needSave: Boolean = true): String =
        owned(bookSource, book, bookChapter) { getContentAwaitOwned(bookSource, book, bookChapter, nextChapterUrl, needSave) }
    suspend fun preciseSearchAwait(bookSource: BookSource, name: String, author: String): Result<Book> =
        owned(bookSource) { preciseSearchAwaitOwned(bookSource, name, author) }
    suspend fun getContentBatchAwait(bookSource: BookSource, book: Book, chapters: List<BookChapter>): List<BookChapter> =
        unsupportedRule("original WebBook contentBatch persistence")
    suspend fun exploreBookAwait(bookSource: BookSource, url: String, page: Int? = 1): ArrayList<SearchBook> =
        unsupportedRule("original WebBook explore navigation/infoMap")
'''+ '\n\n'.join(parts)+'''
    private fun checkRedirect(bookSource: BookSource, response: StrResponse) {
        response.raw().priorResponse?.let { if (it.isRedirect) Debug.log(bookSource.bookSourceUrl, "重定向: ${response.url()}") }
    }
}
'''
s=common(s)
write(Path('io/legado/app/model/webBook/WebBook.kt'),s)
