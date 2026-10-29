import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

// 자연어 해석이나 권한 발급은 하지 않는다. 현재 요청에서 확인한 사실만 분류한다.
export function selectTaskRoute(facts) {
  const missing = fields => ({ route: 'read-context', missing: fields, grantsPermission: false });
  if (!facts || !['inspect', 'diagnose', 'propose', 'plan', 'implement'].includes(facts.intent)) {
    return { route: 'clarify', missing: ['intent'], grantsPermission: false };
  }
  // 현재 결과에 대한 원인 질문은 피드백의 조사 단계다. 편집 권한과는 별개다.
  if (facts.intent === 'diagnose' && facts.kind === 'code' && facts.currentWorkplan && facts.relatedFeedback === true) {
    if (facts.contextComplete !== true) return missing(facts.missingContext?.length ? facts.missingContext : ['project-policy-and-scope']);
    return {
      route: 'feedback', skill: 'apply-workplan-feedback', workplan: 'reuse',
      nextAction: 'investigate-and-propose', deferCompletion: facts.completionRequested === true,
      reasons: ['current-workplan', 'diagnostic-feedback'], grantsPermission: false
    };
  }
  // '원인과 수정 계획'의 두 번째 목적을 일반 진단 반환에서 버리지 않는다.
  if (facts.intent === 'diagnose' && facts.explicitPlanRequested === true) {
    facts = { ...facts, intent: 'plan' };
  }
  if (['inspect', 'diagnose'].includes(facts.intent)) {
    return { route: 'read-only', workplan: false, skill: null, grantsPermission: false };
  }
  if (!['code', 'writing'].includes(facts.kind)) return missing(['kind']);
  if (facts.kind === 'writing') {
    return { route: 'writing-work', skill: null, workplan: false, references: ['writing-work.md'], grantsPermission: false };
  }
  if (facts.contextComplete !== true) return missing(facts.missingContext?.length ? facts.missingContext : ['project-policy-and-scope']);
  if (facts.currentWorkplan && facts.relatedFeedback === true) {
    return { route: 'feedback', skill: 'apply-workplan-feedback', workplan: 'reuse', reasons: ['current-workplan'], grantsPermission: false };
  }

  // 미확인을 false로 바꾸면 위험한 변경도 작은 수정으로 분류되므로 입력에서 구별한다.
  const flags = ['recordRequired', 'explicitPlanRequested', 'complexChange', 'importantDecision', 'contractRisk'];
  const unknown = flags.filter(key => typeof facts[key] !== 'boolean');
  if (!Number.isInteger(facts.repositoryCount) || facts.repositoryCount < 1) unknown.push('repositoryCount');
  if (unknown.length) return missing(unknown);

  const reasons = flags.filter(key => facts[key]);
  if (facts.intent === 'plan' && !reasons.includes('explicitPlanRequested')) reasons.push('explicitPlanRequested');
  if (facts.repositoryCount > 1) reasons.push('multiple-repositories');
  if (reasons.length) {
    if (!['bug', 'feature'].includes(facts.changeKind)) return missing(['changeKind']);
    return {
      route: 'plan', skill: facts.changeKind === 'bug' ? 'bugfix-plan' : 'feature-plan', workplan: true,
      planSize: reasons.every(reason => ['recordRequired', 'explicitPlanRequested'].includes(reason)) ? 'short' : 'normal',
      reasons, grantsPermission: false
    };
  }
  return { route: 'conversation-proposal', skill: 'code-change', workplan: false, reasons: ['known-local-change'], grantsPermission: false };
}

function isEntrypoint(file) {
  if (!file || file === '-') return false;
  try { return import.meta.url === pathToFileURL(realpathSync(file)).href; }
  catch { return false; } // 표준입력·다른 실행기의 가상 경로는 import만 수행한다.
}

if (isEntrypoint(process.argv[1])) {
  if (process.argv.includes('--help')) {
    console.log('node task-route.mjs < facts.json\n확인한 intent/kind/contextComplete와 위험·기록 사실을 표준 입력 JSON으로 받습니다. 수행 권한은 발급하지 않습니다.');
  } else {
    try {
      let input = '';
      for await (const chunk of process.stdin) input += chunk;
      console.log(JSON.stringify(selectTaskRoute(JSON.parse(input)), null, 2));
    }
    catch (error) { console.error(`작업 경로 입력을 읽지 못했습니다: ${error.message}`); process.exitCode = 2; }
  }
}
