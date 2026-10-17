// Local deterministic source: the same functions and argument order as Legado JsSourceEngine.
var invocationOnly = 0;
function login(input) {
    var result = java.connect(baseUrl + '/login,{"method":"POST","body":"name=reader&password=%E4%B9%A6","headers":{"Content-Type":"application/x-www-form-urlencoded"}}');
    source.putLoginInfo('{"name":"reader"}');
    source.putLoginHeader('{"Authorization":"Bearer fixture"}');
    source.putVariable('logged-in');
    return result.code() === 200;
}
function search(key, page) {
    invocationOnly++;
    if (invocationOnly !== 1) throw new Error('Call scope leaked');
    globalThis.calls = (globalThis.calls || 0) + 1;
    cache.put('lastKey', key);
    var result = JSON.parse(java.ajax(baseUrl + '/search?key=' + java.encodeURI(key) + '&page=' + page));
    return result.books;
}
function getBookInfo(book) {
    var html = java.ajax(book.bookUrl);
    var doc = org.jsoup.Jsoup.parse(html);
    book.intro = String(doc.select('#intro').text());
    book.tocUrl = baseUrl + String(doc.select('#toc').attr('href'));
    return book;
}
function getChapters(book) {
    return JSON.parse(java.ajax(book.tocUrl));
}
function getContent(chapter, book, nextChapterUrl) {
    return java.ajax(chapter.url);
}
function getContentBatch(chapters, book) {
    for (var i = 0; i < chapters.length; i++) {
        java.cacheContent(chapters[i].url, getContent(chapters[i], book, null));
    }
}
