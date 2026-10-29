export function formatDocumentDate(value, { timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone } = {}) {
  if (typeof value !== 'string' || !value.trim()) return '시각 미기록';
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const parsed = new Date(`${value}T00:00:00Z`);
    if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) return '시각 확인 불가';
    const [year, month, day] = value.split('-').map(Number);
    // 날짜만 기록된 이력에 자정이나 다른 시간대의 전날 날짜를 만들어 붙이지 않는다.
    return `${year}. ${month}. ${day}. · 시각 미기록`;
  }
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime())) return '시각 확인 불가';
  return new Intl.DateTimeFormat('ko-KR', {
    year: 'numeric', month: 'numeric', day: 'numeric',
    hour: 'numeric', minute: '2-digit', second: '2-digit',
    timeZone, timeZoneName: 'long',
  }).format(parsed);
}
