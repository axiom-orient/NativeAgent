#!/usr/bin/env node
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import * as z from 'zod/v4';
import { writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
const root = process.argv[2];
serveStdio(() => {
  const server = new McpServer({ name: 'official-typescript-proof', version: '2.0.0' });
  server.registerTool('writeProof', {
    description: 'Write synthetic qualification text to the fixed proof file.',
    inputSchema: z.object({ text: z.string() })
  }, async ({ text }, context) => {
    if (text === "CRASH") { process.exit(42); }
    if (text === "DELAY") {
      await new Promise((resolve, reject) => {
        const signal = context.mcpReq.signal;
        const timer = setTimeout(resolve, 30000);
        let aborted = false;
        const abort = () => {
          if (aborted) return;
          aborted = true;
          clearTimeout(timer);
          writeFile(join(root, 'cancelled.txt'), 'cancelled').then(() => reject(new Error('cancelled')), reject);
        };
        signal.addEventListener('abort', abort, { once: true });
        if (signal.aborted) abort();
        writeFile(join(root, 'started.txt'), 'started').catch(reject);
      });
    }
    await writeFile(join(root, 'proof.txt'), text);
    return { content: [{ type: 'text', text: await readFile(join(root, 'proof.txt'), 'utf8') }] };
  });
  return server;
}, { legacy: 'reject', onerror: error => console.error(error) });
