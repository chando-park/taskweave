export const tabs = ['계획', '구현', '코드 흐름', '화면 비교', '테스트', '변경 이력', '추가 문서'];

export function documentTab(doc, mainName = '') {
  if (doc.main) return '계획';
  // 작업 폴더 이름에 test·comparison이 있어도 그 안의 모든 자료를 같은 탭으로 보내지 않는다.
  const directory = mainName.slice(0, mainName.lastIndexOf('/') + 1);
  const name = directory && doc.name.startsWith(directory) ? doc.name.slice(directory.length) : doc.name;
  const media = doc.kind === 'flow' || doc.kind === 'image';
  if (/comparison|화면[-_ ]?(?:비교|검증)|시각[-_ ]?(?:비교|검증)|(?:ui|visual)[-_ ](?:comparison|verification|review)/i.test(name)) return '화면 비교';
  if (media && /(?:^|[/_. -])(?:flow|sequence|diagram|architecture|code[-_ ]?(?:flow|plan|result)|흐름|시퀀스|구조도)(?=[/_. -]|$)/i.test(name)) return '코드 흐름';
  if (doc.kind === 'image' && /(?:figma|candidate|screenshot|snapshot|golden|render)/i.test(name)) return '화면 비교';
  if (/test|verif|검증|테스트/i.test(name)) return '테스트';
  if (/changelog|history|변경/i.test(name)) return '변경 이력';
  if (doc.kind === 'flow' && /(?:^|[/_. -])(?:plan|result)(?=[/_. -]|$)/i.test(name)) return '코드 흐름';
  if (/completion|result|implement|완료|구현/i.test(name)) return '구현';
  if (/plan|계획/i.test(name)) return '계획';
  return '추가 문서';
}

export function documentsForTab(documents, tab) {
  const mainName = documents.find(doc => doc.main)?.name || '';
  const selected = documents.filter(doc => documentTab(doc, mainName) === tab);
  // 개별 PNG보다 설명과 확대 비교를 한곳에 모은 HTML을 먼저 연다. 원본 목록은 바꾸지 않는다.
  if (tab === '화면 비교') selected.sort((a, b) => Number(b.kind === 'flow') - Number(a.kind === 'flow'));
  return selected;
}
