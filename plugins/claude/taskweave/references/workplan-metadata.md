# Workplan Metadata

## 수명주기 시각

- `created`, `updated`, `approved_at`, `verified_at`, `completed_at`은 초와 UTC offset을 포함해 따옴표로 감싼 ISO 8601 문자열을 사용한다. 예: `"2026-08-19T15:48:04+09:00"`.
- 상태, 승인 범위 또는 검증 근거가 바뀔 때마다 `updated`를 갱신한다.
- 기존 `YYYY-MM-DD` 값은 읽기 호환성을 유지하고 일괄 변환하지 않는다. 정확한 과거 시각이나 Raw 원본 날짜를 추정하지 않는다.
- 따옴표 없는 YAML timestamp는 parser가 `Time` 객체로 해석할 수 있으므로 사용하지 않는다.
- `2026-08-21`부터 생성되거나 갱신되는 Workplan은 위 형식을 강제한다.
- 정확한 승인 시각을 복구할 수 없는 legacy 문서만 `lifecycle_timestamp_precision.approved_at: date_only_unrecoverable`과 사유를 사용할 수 있다. 새 승인 기록에는 허용하지 않는다.

상태·경로·본문 분리 규칙은 [Workplan Layout](workplan-layout.md)을 따른다.
