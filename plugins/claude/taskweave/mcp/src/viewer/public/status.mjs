const groups = {
  active: new Set(['approved', 'implementing', 'implemented', 'verifying', 'in_progress', '진행 중']),
  review: new Set(['draft', 'awaiting_approval', 'awaiting_completion', 'needs_reapproval', 'verification_blocked']),
  done: new Set(['completed', 'done', '완료']),
};

const labels = {
  draft: '초안', awaiting_approval: '승인 대기', approved: '승인됨',
  implementing: '구현 중', implemented: '구현됨', verifying: '검증 중',
  awaiting_completion: '최종 확인 대기', completed: '완료',
  needs_reapproval: '재승인 필요', verification_blocked: '검증 대기',
  superseded: '다른 작업으로 대체', in_progress: '진행 중', done: '완료',
};

export function statusGroup(status) {
  return Object.keys(groups).find(group => groups[group].has(status)) || 'other';
}

export function statusLabel(status) {
  return labels[status] || status || '기록 없음';
}
