import { readFile, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { parse } from 'yaml';

const validId = value => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$/.test(value);
const inside = (root, target) => { const relative = path.relative(root, target); return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith(`..${path.sep}`)); };
async function optional(file, format) {
  try {
    if ((await stat(file)).size > 1024 * 1024) throw new Error('작업공간 연결 파일이 너무 큽니다');
    const source = await readFile(file, 'utf8');
    return format === 'json' ? JSON.parse(source) : parse(source);
  } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

// 이미 연결한 작업공간·뷰어 폴더만 확인한다. 홈이나 제품 저장소 전체를 탐색하지 않는다.
export async function workspaceProjects(settings, dataRoot) {
  const linked = await optional(path.join(dataRoot, 'viewer/roots.json'), 'json');
  const candidates = [...Object.values(settings.workspaces).map(item => item.root), ...(linked?.roots ?? []).map(root => path.basename(root) === 'Workplans' ? path.dirname(root) : root)];
  const projects = [], workspaces = {}, warnings = [], seen = new Set();
  for (const candidate of candidates) {
    try {
      const root = await realpath(candidate);
      if (seen.has(root)) continue;
      seen.add(root);
      const registry = await optional(path.join(root, 'workspace.yaml'));
      if (!registry?.projects) continue;
      const local = await optional(path.join(root, 'workspace.local.yaml'));
      const workspaceId = Object.entries(settings.workspaces).find(([, item]) => path.resolve(item.root) === root)?.[0]
        ?? `company-${createHash('sha256').update(root).digest('hex').slice(0, 12)}`;
      workspaces[workspaceId] = { root, trusted: false };
      for (const [projectId, spec] of Object.entries(registry.projects)) {
        const location = local?.paths?.projects?.[projectId];
        if (!validId(projectId) || typeof location !== 'string' || !path.isAbsolute(location) || typeof spec?.workplans !== 'string' || typeof spec?.agent !== 'string') continue;
        try {
          const repositoryPath = await realpath(location);
          const resolveRecord = async relative => {
            if (path.isAbsolute(relative) || !inside(root, path.resolve(root, relative))) throw new Error('작업공간 밖의 기록 경로');
            const target = path.resolve(root, relative);
            // 없는 폴더도 허용하지만 기존 상위 symlink가 외부로 나가면 연결하지 않는다.
            let ancestor = target;
            while (true) {
              try { if (!inside(root, await realpath(ancestor))) throw new Error('작업공간 밖의 연결 경로'); break; }
              catch (error) { if (error.code !== 'ENOENT') throw error; ancestor = path.dirname(ancestor); }
            }
            if (inside(repositoryPath, target)) throw new Error('제품 저장소 안의 기록 경로');
            return target;
          };
          projects.push({ projectId, workspaceId, repositoryPath, executionTrusted: false,
            workplanRoot: settings.workplanStorage === 'managed-default-v1'
              ? path.join(dataRoot, 'workspaces/personal/projects', projectId, 'Workplans')
              : await resolveRecord(spec.workplans),
            productMemoryRoot: await resolveRecord(registry.knowledge?.product_memory ?? 'ProductMemory'),
            instructionsRoot: await resolveRecord(path.dirname(spec.agent)) });
        } catch (error) { if (error.code !== 'ENOENT') warnings.push(`${projectId}: ${error.message}`); }
      }
    } catch (error) { if (error.code !== 'ENOENT') warnings.push(`${candidate}: ${error.message}`); }
  }
  return { projects, workspaces, warnings };
}
