import ../ws, chronos, asynchttpserver

proc cb(req: Request) {.async.} =
  var ws = await newWebSocket(req)
  ws.close()

var server = newAsyncHttpServer()
waitFor server.serve(Port(9001), cb)
