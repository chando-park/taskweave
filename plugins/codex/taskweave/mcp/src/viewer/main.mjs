import { pathToFileURL } from 'node:url';
import { createCatalog } from './reader.mjs';
import { createViewerServer } from './server.mjs';
import { PRODUCT_NAME } from '../product.mjs';

export function parseArguments(args) {
  const options={roots:[],port:0};
  for (let i=0;i<args.length;i++) {
    if (args[i] === '--root' && args[i+1] && !args[i+1].startsWith('--')) options.roots.push(args[++i]);
    else if (args[i] === '--port' && /^\d+$/.test(args[i+1] || '')) options.port=Number(args[++i]);
    else if (args[i] === '--help' || args[i] === '-h') options.help=true;
    else throw new Error(`알 수 없거나 값이 없는 옵션: ${args[i]}`);
  }
  if (options.port > 65535) throw new Error('--port는 0~65535 범위여야 합니다.');
  return options;
}
export async function startViewer({roots,port=0,instance,...limits}) {
  const catalog=await createCatalog({roots,...limits}); await catalog.refresh();
  const server=createViewerServer({catalog,instance});
  await new Promise((resolve,reject) => { server.once('error',reject); server.listen(port,'127.0.0.1',resolve); });
  return {server,catalog,url:`http://127.0.0.1:${server.address().port}`};
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const options=parseArguments(process.argv.slice(2));
    if (options.help) console.log(`${PRODUCT_NAME} 조회 전용 뷰어\nnode src/viewer/main.mjs --root /절대경로/Workplans [--root /다른/Workplans] [--port 0]`);
    else { const {url}=await startViewer(options); console.log(`${PRODUCT_NAME} · ${url}\n조회 전용입니다. 종료: Ctrl+C`); }
  } catch (error) { console.error(`뷰어를 시작하지 못했습니다: ${error.message}`); process.exitCode=1; }
}
