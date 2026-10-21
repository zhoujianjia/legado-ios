from pathlib import Path
import difflib,hashlib,json,subprocess

R=Path('F:/yuedu-reader');S=Path(__file__).resolve().parent
SOURCE='88c61ee4b80889a617d344fda668d077f73fa95b';G='D:/app/Git/cmd/git.exe'
PREFIX='Packages/LegadoRuntime/jvm/src/test/kotlin/io/yuedu/legado/'
NAMES=['OriginalAnalyzeRuleTest.kt','OriginalSourceLoginBrowserAwaitTest.kt','OriginalSourceLoginBrowserTest.kt','OriginalSourceLoginV2BrowserTest.kt','OriginalUrlExecutionTest.kt']
def rf(b):return {'bytes':len(b),'sha256':hashlib.sha256(b).hexdigest()}
def wr(p,b):p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b)
def once(t,a,b):assert t.count(a)==1,a;return t.replace(a,b,1)
texts={}
for name in NAMES:
 rel=PREFIX+name;b=subprocess.check_output([G,'show',SOURCE+':'+rel],cwd=R);assert b==(R/rel).read_bytes();wr(S/'rawbaseline'/rel,b);texts[name]=b.decode('utf8')

n=NAMES[0];texts[n]=once(texts[n],'''        assertThrows(Exception::class.java) { rule.evalJS("java.base64Decode('aGVsbG8=',0)") }''','''        // The no-flags overloads above remain Hutool. The separate Android
        // flags overload is now implemented; DEFAULT=0 decodes this same text.
        assertEquals("hello", rule.evalJS("java.base64Decode('aGVsbG8=',0)"))
        assertThrows(Exception::class.java) { rule.evalJS("java.base64Decode('A',0)") }''')

n=NAMES[1];texts[n]=once(texts[n],'''            for(script in listOf("java.startBrowserAwait('https://synthetic-await.invalid/page','HTML',false,'');")){
                assertEquals("UNSUPPORTED_CAPABILITY",owned.call(script,success=false)["error"].asJsonObject["code"].asString)
            }
            assertEquals(count,owned.pages.size);assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpHostCalls)''','''            for(script in listOf("java.startBrowserAwait('file:///private/synthetic','Not web',false);")){
                assertEquals("UNSUPPORTED_CAPABILITY",owned.call(script,success=false)["error"].asJsonObject["code"].asString)
            }
            assertEquals(count,owned.pages.size)
            // Explicit local HTML now has a same-session page. The false mode
            // must consume the actual atomic DOM response, without refetch.
            owned.mode="response";owned.body="<html>local-dom</html>"
            val html=owned.call("var r=java.startBrowserAwait('https://synthetic-await.invalid/page','HTML',false,'');if(String(r.body())!=='<html>local-dom</html>')throw Error('lost actual DOM');")
            assertEquals(count+1,owned.pages.size)
            val page=owned.pages.last();assertTrue(page.has("localPage"));assertTrue(page["prefetchedHTML"].asString.isNotEmpty())
            assertFalse(page["refetchAfterSuccess"].asBoolean)
            assertTrue(html["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserCookieCaptureCompleted"})
            assertEquals(0,owned.credentialCalls);assertEquals(0,owned.httpHostCalls)''')

n=NAMES[2];texts[n]=once(texts[n],'''                "java.startBrowser('https://synthetic-browser.invalid/page','HTML','');",
''','')
texts[n]=once(texts[n],'''            assertTrue(owned.pages.isEmpty());assertEquals(0,owned.httpCalls);assertEquals(0,owned.credentialCalls)''','''            assertTrue(owned.pages.isEmpty())
            // Preserve the historical test identity while migrating only the
            // explicit-HTML branch that the original local-page slice enabled.
            val accepted=owned.call("java.startBrowser('https://synthetic-browser.invalid/page','HTML','');")
            val page=owned.pages.single();assertTrue(page.has("localPage"));assertTrue(page["prefetchedHTML"].asString.isNotEmpty())
            assertFalse(page["awaitsResult"].asBoolean)
            assertTrue(accepted["completedEffects"].asJsonArray.any{it.asString=="sourceBrowserPresented"})
            assertEquals(0,owned.httpCalls);assertEquals(0,owned.credentialCalls)''')

n=NAMES[3];texts[n]=once(texts[n],'''            for(script in listOf("java.startBrowser('${peer.origin}/local','Local','<html>x</html>');", "source.startBrowserAwait('${peer.origin}/local','Local',false,'');")) {
                val rejected=owned.action(script,success=false)
                assertEquals("UNSUPPORTED_CAPABILITY",rejected["error"].asJsonObject["code"].asString)
            }
            assertEquals(1,owned.pages.size);assertTrue(peer.routes.isEmpty());assertEquals(0,owned.credentials)''','''            // The already-accepted script failure above remains an error with
            // its Presented effect. Explicit local HTML is now a real branch.
            owned.action("java.startBrowser('${peer.origin}/local','Local','<html>x</html>');")
            owned.mode="response"
            owned.action("var r=source.startBrowserAwait('${peer.origin}/local','Local',false,'');if(String(r.body())!=='<html>dom</html>')throw Error('lost DOM');")
            assertEquals(3,owned.pages.size)
            assertTrue(owned.pages[1]["prefetchedHTML"].asString.contains("<html>x</html>"))
            assertTrue(owned.pages.drop(1).all{it.has("localPage")&&it["prefetchedHTML"].asString.isNotEmpty()})
            assertFalse(owned.pages.last()["refetchAfterSuccess"].asBoolean)
            for(script in listOf("java.showBrowser('${peer.origin}/blocked');", "source.startBrowser('file:///private/synthetic','Not web');")) {
                val rejected=owned.action(script,success=false)
                assertEquals("UNSUPPORTED_CAPABILITY",rejected["error"].asJsonObject["code"].asString)
            }
            assertEquals(3,owned.pages.size);assertTrue(peer.routes.isEmpty());assertEquals(0,owned.credentials);assertEquals(0,owned.nativeHTTP)''')

n=NAMES[4];texts[n]=once(texts[n],'''                owned.environment.use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned")).use { rule ->
                        listOf("webView", "type", "webJs", "unknown").forEach { option ->''','''                owned.environment.use { environment ->
                    AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned")).use { rule ->
                        // webView remains denied without its checked source
                        // owner; type/unknown remain constructor rejections.
                        listOf("webView", "type", "unknown").forEach { option ->''')
texts[n]=once(texts[n],'''                    assertTrue(peer.requests.isEmpty())
                }
            }
        }
    }

    @Test(timeout = 15_000) fun escapingNestedUnsupportedRemainsTypedButScriptCanCatchIt()''','''                    assertTrue(peer.requests.isEmpty())
                    val browserCalls=java.util.concurrent.atomic.AtomicInteger()
                    LegadoRuntime.setHostCallback { _, operation, _ ->
                        if(operation=="source.webview")browserCalls.incrementAndGet()
                        error("Unexpected native host: $operation")
                    }
                    try {
                        AnalyzeRule(source = RuleSource(environment, peer.origin, "Owned")).use { rule ->
                            // webJs alone does not enable option.webView. Both
                            // public request overloads must retain original HTTP.
                            val url=peer.origin+"/script-only,{\\\"webJs\\\":\\\"throw Error('must not run')\\\"}"
                            assertEquals("unexpected",rule.connect(url).body())
                            assertEquals("unexpected",rule.ajax(url))
                        }
                        assertEquals(listOf("/script-only","/script-only"),peer.requests.map{it.path})
                        assertEquals(0,browserCalls.get())
                    } finally {LegadoRuntime.setHostCallback(null)}
                }
            }
        }
    }

    @Test(timeout = 15_000) fun escapingNestedUnsupportedRemainsTypedButScriptCanCatchIt()''')
rows=[]
for name,text in texts.items():
 rel=PREFIX+name;old=(S/'rawbaseline'/rel).read_bytes();new=text.encode('utf8');wr(S/'work'/rel,new)
 diff=''.join(difflib.unified_diff(old.decode('utf8').splitlines(True),text.splitlines(True),fromfile='a/'+rel,tofile='b/'+rel)).encode('utf8');dp=S/'diffs'/(rel+'.diff');wr(dp,diff)
 rows.append({'path':rel,'baseline':rf(old),'candidate':rf(new),'diff':{'path':dp.relative_to(R).as_posix(),**rf(diff)}})
wr(S/'draft-v1.json',(json.dumps({'sourceCommit':SOURCE,'scope':'Five existing JUnit methods only; no production changes or new test definitions. SDK0/JNI0.','files':rows},indent=2)+'\n').encode())
print(json.dumps({'files':len(rows),'draft':rf((S/'draft-v1.json').read_bytes())}))
