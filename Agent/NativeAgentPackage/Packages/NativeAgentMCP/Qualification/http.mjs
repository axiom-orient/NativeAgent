import { McpServer, createMcpHandler } from '@modelcontextprotocol/server';
import { createServer } from 'node:http';
import { appendFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import * as z from 'zod/v4';
const root = process.argv[2];
const handler = createMcpHandler(() => {
 const server = new McpServer({name:'auth-proof',version:'2.0.0'});
 server.registerTool('proof',{description:'Return qualification marker',inputSchema:z.object({})},async()=>({content:[{type:'text',text:'AUTH_OK'}]}));
 return server;
},{legacy:'reject',responseMode:'json'});
const server = createServer(async (req,res) => {
 await appendFile(join(root,'requests.log'), (req.headers.authorization === 'Bearer qualification-only' ? 'valid' : 'invalid')+'\n');
 if(req.headers.authorization !== 'Bearer qualification-only') {
   res.writeHead(401,{'WWW-Authenticate':'Bearer realm="qualification"'});res.end('unauthorized');return;
 }
 try {
  const body=[];for await(const chunk of req)body.push(chunk);
  const response=await handler.fetch(new Request('http://127.0.0.1'+req.url,{method:req.method,headers:req.headers,body:Buffer.concat(body)}));
  res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));
 }catch(error){res.writeHead(500);res.end(String(error));}
});
server.listen(0,'127.0.0.1',async()=>await writeFile(join(root,'port'),String(server.address().port)));
process.on('SIGTERM',()=>{handler.close().finally(()=>server.close(()=>process.exit(0)));});
