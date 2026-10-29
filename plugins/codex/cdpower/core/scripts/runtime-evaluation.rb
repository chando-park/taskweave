#!/usr/bin/env ruby

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"
require "time"
require "yaml"

module RuntimeEvaluation
  class EvaluationError < StandardError; end

  SCHEMA_VERSION = 1
  CASE_PATTERN = /\Acase-\d{2}\z/
  PILOT_PATTERN = /\Aruntime-pilot-\d{4}-\d{2}\z/
  RULE_PATTERN = /\A[a-z0-9][a-z0-9-]*\z/
  TYPES = %w[bug feature].freeze
  ROUTES = %w[direct workplan].freeze
  RISKS = %w[low medium high].freeze
  MODELS = %w[none terra luna spark sol].freeze
  REVIEW_MODELS = %w[terra sol].freeze
  SINGLETON_EVENTS = %w[
    case_started plan_ready approval_received implementation_started
    implementation_finished verification_started verification_finished
    completion_requested completed
  ].freeze
  REPEATABLE_EVENTS = %w[
    user_question reapproval rework missed_requirement verification_retry bottleneck rule_used
  ].freeze
  EVENTS = (SINGLETON_EVENTS + REPEATABLE_EVENTS).freeze
  CATEGORIES = {
    "user_question" => %w[product_decision discoverable scope_change],
    "reapproval" => %w[scope_change],
    "rework" => %w[missed_source missed_context plan_gap implementation_error verification_error environment scope_change],
    "missed_requirement" => %w[source context plan implementation verification],
    "verification_retry" => %w[code environment runner cache],
    "bottleneck" => %w[docs jira dispatch compile test_runner ui_render product_memory git environment]
  }.freeze
  OUTCOMES = %w[passed blocked accepted_with_limitations].freeze
  DEFAULT_RULES = %w[
    risk-routing model-routing context-pack implementation-handoff
    code-comment-contract verification-evidence ui-verification
    knowledge-lifecycle workplan-layout ticket-lifecycle
  ].freeze
  EVENT_KEYS = %w[
    schema_version event_id case_id event recorded_at task_type route risk
    planning_model implementation_model review_model category duration_seconds rule outcome
  ].freeze

  class Pilot
    attr_reader :root, :clock

    def initialize(root:, clock: -> { Time.now })
      @root = Pathname(root).expand_path
      @clock = clock
    end

    def init(id:, bug_count:, feature_count:)
      validate_pilot_id!(id)
      raise EvaluationError, "bug·feature 목표는 1 이상이어야 합니다." if bug_count < 1 || feature_count < 1
      raise EvaluationError, "이미 활성 pilot이 있습니다: #{active_id}" if active_id

      directory = root.join(id)
      raise EvaluationError, "pilot 경로가 이미 존재합니다: #{directory}" if directory.exist?

      FileUtils.mkdir_p(directory)
      config = {
        "schema_version" => SCHEMA_VERSION,
        "id" => id,
        "active" => true,
        "created_at" => timestamp,
        "target" => { "bugs" => bug_count, "features" => feature_count },
        "observed_rules" => DEFAULT_RULES
      }
      directory.join("pilot.yml").write(YAML.dump(config), encoding: "UTF-8")
      directory.join("events.jsonl").write("", encoding: "UTF-8")
      Report.new(config: config, events: []).write(directory.join("report.md"))
      directory
    end

    def active_id
      active_configs.map { |path, data| data.fetch("id") }.tap do |ids|
        raise EvaluationError, "활성 pilot이 둘 이상입니다: #{ids.join(', ')}" if ids.length > 1
      end.first
    end

    def active_directory
      id = active_id
      raise EvaluationError, "활성 Runtime pilot이 없습니다." unless id

      root.join(id)
    end

    def config
      load_config(active_directory.join("pilot.yml"))
    end

    def events
      EventStore.new(active_directory.join("events.jsonl")).read.each_with_object([]) do |event, validated|
        EventValidator.new(config: config, events: validated).validate!(event)
        validated << event
      end
    end

    def start_case(task_type:, route:, risk:, planning_model:, implementation_model:, review_model:)
      validate_enum!(task_type, TYPES, "task type")
      validate_enum!(route, ROUTES, "route")
      validate_enum!(risk, RISKS, "risk")
      validate_enum!(planning_model, MODELS, "planning model")
      validate_enum!(implementation_model, MODELS - ["none"], "implementation model")
      validate_enum!(review_model, REVIEW_MODELS, "review model")
      raise EvaluationError, "Direct fix의 planning model은 none이어야 합니다." if route == "direct" && planning_model != "none"
      raise EvaluationError, "Workplan의 planning model은 none일 수 없습니다." if route == "workplan" && planning_model == "none"

      current = events
      starts = current.select { |event| event["event"] == "case_started" }
      type_limit = config.fetch("target").fetch(task_type == "bug" ? "bugs" : "features")
      used = starts.count { |event| event["task_type"] == task_type }
      raise EvaluationError, "#{task_type} case 목표 #{type_limit}건을 이미 채웠습니다." if used >= type_limit

      attempts = 0
      begin
        starts = events.select { |event| event["event"] == "case_started" }
        case_id = format("case-%02d", starts.length + 1)
        append(
          "case_id" => case_id,
          "event" => "case_started",
          "task_type" => task_type,
          "route" => route,
          "risk" => risk,
          "planning_model" => planning_model,
          "implementation_model" => implementation_model,
          "review_model" => review_model
        )
        case_id
      rescue EvaluationError => error
        attempts += 1
        retry if attempts < 3 && error.message.include?("중복 수명주기 이벤트")
        raise
      end
    end

    def record(case_id:, name:, category: nil, duration_seconds: nil, rule: nil, outcome: nil)
      validate_case_id!(case_id)
      validate_enum!(name, EVENTS, "event")
      event = { "case_id" => case_id, "event" => name }

      if CATEGORIES.key?(name)
        validate_enum!(category, CATEGORIES.fetch(name), "#{name} category")
        event["category"] = category
      elsif category
        raise EvaluationError, "#{name} 이벤트에는 category를 기록할 수 없습니다."
      end

      if name == "bottleneck"
        unless duration_seconds.is_a?(Integer) && duration_seconds.positive?
          raise EvaluationError, "bottleneck에는 양의 정수 --duration-seconds가 필요합니다."
        end
        event["duration_seconds"] = duration_seconds
      elsif duration_seconds
        raise EvaluationError, "#{name} 이벤트에는 duration_seconds를 기록할 수 없습니다."
      end

      if name == "rule_used"
        raise EvaluationError, "rule_used에는 --rule이 필요합니다." if rule.to_s.empty?
        raise EvaluationError, "허용되지 않는 rule ID입니다: #{rule}" unless rule.match?(RULE_PATTERN)
        raise EvaluationError, "pilot 관찰 대상이 아닌 rule입니다: #{rule}" unless config.fetch("observed_rules").include?(rule)
        event["rule"] = rule
      elsif rule
        raise EvaluationError, "#{name} 이벤트에는 rule을 기록할 수 없습니다."
      end

      if name == "verification_finished"
        validate_enum!(outcome, OUTCOMES, "verification outcome")
        event["outcome"] = outcome
      elsif outcome
        raise EvaluationError, "#{name} 이벤트에는 outcome을 기록할 수 없습니다."
      end

      append(event)
    end

    def report
      data = config
      output = active_directory.join("report.md")
      Report.new(config: data, events: events).write(output)
      output
    end

    private

    def append(event)
      event = event.merge(
        "schema_version" => SCHEMA_VERSION,
        "event_id" => SecureRandom.uuid,
        "recorded_at" => timestamp
      )
      EventStore.new(active_directory.join("events.jsonl")).append(event) do |existing|
        EventValidator.new(config: config, events: existing).validate!(event)
      end
      event
    end

    def active_configs
      return [] unless root.directory?

      root.glob("*/pilot.yml").each_with_object([]) do |path, result|
        data = load_config(path)
        result << [path, data] if data["active"] == true
      end
    end

    def load_config(path)
      data = YAML.safe_load(path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false) || {}
      raise EvaluationError, "지원하지 않는 pilot schema입니다: #{path}" unless data["schema_version"] == SCHEMA_VERSION
      validate_pilot_id!(data["id"])
      rules = data["observed_rules"]
      raise EvaluationError, "pilot observed_rules가 배열이 아닙니다: #{path}" unless rules.is_a?(Array)
      unknown_rules = rules - DEFAULT_RULES
      raise EvaluationError, "회사·제품 식별 가능성이 있는 관찰 rule입니다: #{unknown_rules.join(', ')}" unless unknown_rules.empty?
      data
    rescue Psych::SyntaxError => error
      raise EvaluationError, "pilot 설정 YAML이 손상되었습니다: #{error.message}"
    end

    def validate_pilot_id!(id)
      raise EvaluationError, "허용되지 않는 pilot ID입니다: #{id}" unless id.to_s.match?(PILOT_PATTERN)
    end

    def validate_case_id!(id)
      raise EvaluationError, "허용되지 않는 case ID입니다: #{id}" unless id.to_s.match?(CASE_PATTERN)
    end

    def validate_enum!(value, allowed, label)
      raise EvaluationError, "지원하지 않는 #{label}입니다: #{value}" unless allowed.include?(value)
    end

    def timestamp
      clock.call.iso8601
    end
  end

  class EventStore
    def initialize(path)
      @path = Pathname(path)
    end

    def append(event)
      @path.open("a+:UTF-8") do |file|
        # 여러 Codex 작업이 같은 pilot을 사용할 때 ID 선택·검증·추가를 하나의 임계 구역으로 묶는다.
        file.flock(File::LOCK_EX)
        file.rewind
        existing = parse_lines(file.each_line)
        yield existing if block_given?
        file.seek(0, IO::SEEK_END)
        file.puts(JSON.generate(event))
        file.flush
        file.flock(File::LOCK_UN)
      end
    end

    def read
      return [] unless @path.file?

      parse_lines(@path.each_line)
    end

    private

    def parse_lines(lines)
      lines.with_index(1).each_with_object([]) do |(line, index), events|
        next if line.strip.empty?
        events << JSON.parse(line)
      rescue JSON::ParserError => error
        raise EvaluationError, "events.jsonl #{index}행이 손상되었습니다: #{error.message}"
      end
    end
  end

  class EventValidator
    def initialize(config:, events:)
      @config = config
      @events = events
    end

    def validate!(event)
      unknown = event.keys - EVENT_KEYS
      raise EvaluationError, "허용되지 않는 이벤트 필드입니다: #{unknown.join(', ')}" unless unknown.empty?
      raise EvaluationError, "허용되지 않는 case ID입니다: #{event['case_id']}" unless event["case_id"].to_s.match?(CASE_PATTERN)
      raise EvaluationError, "지원하지 않는 이벤트입니다: #{event['event']}" unless EVENTS.include?(event["event"])
      Time.iso8601(event.fetch("recorded_at"))

      validate_case_presence!(event)
      validate_singleton!(event)
      validate_order!(event)
      validate_payload!(event)
      true
    rescue ArgumentError
      raise EvaluationError, "이벤트 시각은 offset을 포함한 ISO 8601이어야 합니다: #{event['recorded_at']}"
    end

    private

    def case_events(case_id)
      @events.select { |item| item["case_id"] == case_id }
    end

    def validate_case_presence!(event)
      return if event["event"] == "case_started"
      raise EvaluationError, "시작되지 않은 case입니다: #{event['case_id']}" unless case_events(event["case_id"]).any? { |item| item["event"] == "case_started" }
    end

    def validate_singleton!(event)
      return unless SINGLETON_EVENTS.include?(event["event"])
      if case_events(event["case_id"]).any? { |item| item["event"] == event["event"] }
        raise EvaluationError, "중복 수명주기 이벤트입니다: #{event['case_id']} #{event['event']}"
      end
    end

    def validate_order!(event)
      names = case_events(event["case_id"]).map { |item| item["event"] }
      started = case_events(event["case_id"]).find { |item| item["event"] == "case_started" }
      route = event["event"] == "case_started" ? event["route"] : started && started["route"]
      prerequisites = {
        "plan_ready" => ["case_started"],
        "approval_received" => ["plan_ready"],
        "implementation_started" => route == "workplan" ? ["approval_received"] : ["case_started"],
        "implementation_finished" => ["implementation_started"],
        "verification_started" => ["implementation_finished"],
        "verification_finished" => ["verification_started"],
        "completion_requested" => ["verification_finished"],
        "completed" => ["completion_requested"]
      }
      Array(prerequisites[event["event"]]).each do |required|
        raise EvaluationError, "#{event['event']} 전에 #{required}가 필요합니다." unless names.include?(required)
      end
      if route == "direct" && %w[plan_ready approval_received reapproval].include?(event["event"])
        raise EvaluationError, "Direct fix에는 #{event['event']}를 기록할 수 없습니다."
      end
      raise EvaluationError, "완료된 case에는 이벤트를 추가할 수 없습니다." if names.include?("completed")
    end

    def validate_payload!(event)
      if event["event"] == "case_started"
        raise EvaluationError, "case_started 필드가 누락되었습니다." unless %w[task_type route risk planning_model implementation_model review_model].all? { |key| !event[key].to_s.empty? }
        ensure_in!(event["task_type"], TYPES, "task type")
        ensure_in!(event["route"], ROUTES, "route")
        ensure_in!(event["risk"], RISKS, "risk")
        ensure_in!(event["planning_model"], MODELS, "planning model")
        ensure_in!(event["implementation_model"], MODELS - ["none"], "implementation model")
        ensure_in!(event["review_model"], REVIEW_MODELS, "review model")
        if event["route"] == "direct" && event["planning_model"] != "none"
          raise EvaluationError, "Direct fix의 planning model은 none이어야 합니다."
        end
        if event["route"] == "workplan" && event["planning_model"] == "none"
          raise EvaluationError, "Workplan의 planning model은 none일 수 없습니다."
        end
        target_key = event["task_type"] == "bug" ? "bugs" : "features"
        limit = @config.fetch("target").fetch(target_key)
        used = @events.count { |item| item["event"] == "case_started" && item["task_type"] == event["task_type"] }
        raise EvaluationError, "#{event['task_type']} case 목표 #{limit}건을 이미 채웠습니다." if used >= limit
      end
      if CATEGORIES.key?(event["event"])
        allowed = CATEGORIES.fetch(event["event"])
        raise EvaluationError, "지원하지 않는 category입니다: #{event['category']}" unless allowed.include?(event["category"])
      end
      if event["event"] == "bottleneck"
        duration = event["duration_seconds"]
        unless duration.is_a?(Integer) && duration.positive?
          raise EvaluationError, "bottleneck duration_seconds는 양의 정수여야 합니다."
        end
      elsif event.key?("duration_seconds")
        raise EvaluationError, "#{event['event']} 이벤트에는 duration_seconds를 기록할 수 없습니다."
      end
      if event["event"] == "rule_used"
        rule = event["rule"].to_s
        raise EvaluationError, "허용되지 않는 rule ID입니다: #{rule}" unless rule.match?(RULE_PATTERN)
        raise EvaluationError, "pilot 관찰 대상이 아닌 rule입니다: #{rule}" unless @config.fetch("observed_rules").include?(rule)
      end
      if event["event"] == "verification_finished"
        raise EvaluationError, "지원하지 않는 검증 outcome입니다: #{event['outcome']}" unless OUTCOMES.include?(event["outcome"])
      end
    end

    def ensure_in!(value, allowed, label)
      raise EvaluationError, "지원하지 않는 #{label}입니다: #{value}" unless allowed.include?(value)
    end
  end

  class Report
    def initialize(config:, events:)
      @config = config
      @events = events
    end

    def write(path)
      Pathname(path).write(render, encoding: "UTF-8")
    end

    def render
      cases = grouped_cases
      completed = cases.count { |_id, events| event_time(events, "completed") }
      targets = @config.fetch("target")
      expected = targets.fetch("bugs") + targets.fetch("features")
      verdict = completed == expected && distribution_complete?(cases) ? "sufficient" : "partial"

      lines = []
      lines << "# Runtime Pilot 결과"
      lines << ""
      lines << "## 진행 현황"
      lines << ""
      lines << "- 판정: `#{verdict}`"
      lines << "- 완료: #{completed}/#{expected}"
      lines << "- 버그: #{completed_count(cases, 'bug')}/#{targets.fetch('bugs')}"
      lines << "- 기능: #{completed_count(cases, 'feature')}/#{targets.fetch('features')}"
      lines << "- 주의: 5건 표본은 방향성 확인용이며 통계적 유의성을 뜻하지 않는다."
      lines << ""
      lines << "## 사례별 비용"
      lines << ""
      lines << "| Case | 유형 | 위험 | 경로 | 활성 시간 | 승인 대기 | 완료 대기 | 질문 | 재작업 | 누락 | 검증 재시도 |"
      lines << "| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"
      cases.sort.each do |case_id, events|
        start = events.find { |event| event["event"] == "case_started" } || {}
        lines << "| #{case_id} | #{start['task_type'] || '-'} | #{start['risk'] || '-'} | #{start['route'] || '-'} | #{duration_text(active_duration(events))} | #{duration_text(duration(events, 'plan_ready', 'approval_received'))} | #{duration_text(duration(events, 'verification_finished', 'completion_requested'))} | #{count(events, 'user_question')} | #{count(events, 'rework')} | #{count(events, 'missed_requirement')} | #{count(events, 'verification_retry')} |"
      end
      lines << ""
      lines << "## 경로별 집계"
      lines << ""
      lines << "| 위험 | 경로 | 사례 | 평균 활성 시간 | 질문 | 재작업 | 누락 |"
      lines << "| --- | --- | ---: | ---: | ---: | ---: | ---: |"
      route_groups(cases).each do |(risk, route), values|
        durations = values.map { |_id, events| active_duration(events) }.compact
        average = durations.empty? ? nil : durations.sum / durations.length
        lines << "| #{risk} | #{route} | #{values.length} | #{duration_text(average)} | #{sum(values, 'user_question')} | #{sum(values, 'rework')} | #{sum(values, 'missed_requirement')} |"
      end
      lines << ""
      lines << "## 모델 사용"
      lines << ""
      lines << "| 모델 | 계획 | 구현 | 리뷰 |"
      lines << "| --- | ---: | ---: | ---: |"
      MODELS.reject { |model| model == "none" }.each do |model|
        starts = cases.values.map { |events| events.find { |event| event["event"] == "case_started" } }.compact
        planning = starts.count { |event| event["planning_model"] == model }
        implementation = starts.count { |event| event["implementation_model"] == model }
        review = starts.count { |event| event["review_model"] == model }
        lines << "| #{model} | #{planning} | #{implementation} | #{review} |" if planning + implementation + review > 0
      end
      lines << ""
      lines << "## 병목 시간"
      lines << ""
      bottlenecks = @events.select { |event| event["event"] == "bottleneck" }
                           .group_by { |event| event["category"] }
                           .transform_values { |events| events.sum { |event| event.fetch("duration_seconds") } }
                           .sort.to_h
      lines.concat(bottlenecks.empty? ? ["- 기록 없음"] : bottlenecks.map { |category, seconds| "- `#{category}`: #{duration_text(seconds)}" })
      lines << ""
      lines << "## 반복 실패"
      lines << ""
      repeated = repeated_failures
      lines.concat(repeated.empty? ? ["- 없음"] : repeated.map { |key, value| "- `#{key}`: #{value}회" })
      lines << ""
      lines << "## 제거 검토 후보"
      lines << ""
      if completed < expected
        lines << "- 5건 완료 후 판정"
      else
        unused = @config.fetch("observed_rules") - @events.select { |event| event["event"] == "rule_used" }.map { |event| event["rule"] }.uniq
        lines.concat(unused.empty? ? ["- 없음"] : unused.map { |rule| "- `#{rule}`: 이번 pilot에서 결과 판정 사용 0회" })
      end
      lines << ""
      lines.join("\n")
    end

    private

    def grouped_cases
      @events.group_by { |event| event["case_id"] }
    end

    def completed_count(cases, type)
      cases.count do |_id, events|
        start = events.find { |event| event["event"] == "case_started" }
        start && start["task_type"] == type && event_time(events, "completed")
      end
    end

    def distribution_complete?(cases)
      completed_count(cases, "bug") == @config.fetch("target").fetch("bugs") &&
        completed_count(cases, "feature") == @config.fetch("target").fetch("features")
    end

    def event_time(events, name)
      event = events.find { |item| item["event"] == name }
      event && Time.iso8601(event.fetch("recorded_at"))
    end

    def duration(events, from, to)
      start = event_time(events, from)
      finish = event_time(events, to)
      start && finish ? finish - start : nil
    end

    def active_duration(events)
      values = [
        duration(events, "case_started", "plan_ready"),
        duration(events, "implementation_started", "implementation_finished"),
        duration(events, "verification_started", "verification_finished")
      ].compact
      values.empty? ? nil : values.sum
    end

    def duration_text(seconds)
      seconds ? "#{(seconds / 60.0).round(1)}분" : "-"
    end

    def count(events, name)
      events.count { |event| event["event"] == name }
    end

    def route_groups(cases)
      cases.sort.group_by do |_id, events|
        start = events.find { |event| event["event"] == "case_started" } || {}
        [start["risk"] || "-", start["route"] || "-"]
      end.sort.to_h
    end

    def sum(values, event_name)
      values.sum { |_id, events| count(events, event_name) }
    end

    def repeated_failures
      names = %w[rework missed_requirement verification_retry]
      counts = @events.each_with_object(Hash.new(0)) do |event, result|
        next unless names.include?(event["event"])
        key = [event["event"], event["category"]].compact.join(":")
        result[key] += 1
      end
      counts.select { |_key, value| value >= 2 }.sort.to_h
    end
  end

  class CLI
    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
    end

    def run
      command = @argv.shift || raise(EvaluationError, usage)
      options = { root: default_root }
      case command
      when "init" then run_init(options)
      when "active" then run_active(options)
      when "start" then run_start(options)
      when "event" then run_event(options)
      when "report" then run_report(options)
      else raise EvaluationError, "지원하지 않는 명령입니다: #{command}\n#{usage}"
      end
      0
    rescue EvaluationError, OptionParser::ParseError => error
      @err.puts(error.message)
      1
    end

    private

    def run_init(options)
      parser(options).tap do |cli|
        cli.on("--id ID") { |value| options[:id] = value }
        cli.on("--bug-count N", Integer) { |value| options[:bug_count] = value }
        cli.on("--feature-count N", Integer) { |value| options[:feature_count] = value }
      end.parse!(@argv)
      directory = pilot(options).init(
        id: options.fetch(:id),
        bug_count: options.fetch(:bug_count),
        feature_count: options.fetch(:feature_count)
      )
      @out.puts(directory)
    rescue KeyError => error
      raise EvaluationError, "필수 init 옵션이 없습니다: #{error.key}"
    end

    def run_active(options)
      parser(options).parse!(@argv)
      @out.puts(pilot(options).active_id || raise(EvaluationError, "활성 Runtime pilot이 없습니다."))
    end

    def run_start(options)
      parser(options).tap do |cli|
        cli.on("--type TYPE") { |value| options[:task_type] = value }
        cli.on("--route ROUTE") { |value| options[:route] = value }
        cli.on("--risk RISK") { |value| options[:risk] = value }
        cli.on("--planning-model MODEL") { |value| options[:planning_model] = value }
        cli.on("--implementation-model MODEL") { |value| options[:implementation_model] = value }
        cli.on("--review-model MODEL") { |value| options[:review_model] = value }
      end.parse!(@argv)
      id = pilot(options).start_case(
        task_type: options.fetch(:task_type),
        route: options.fetch(:route),
        risk: options.fetch(:risk),
        planning_model: options.fetch(:planning_model),
        implementation_model: options.fetch(:implementation_model),
        review_model: options.fetch(:review_model)
      )
      @out.puts(id)
    rescue KeyError => error
      raise EvaluationError, "필수 start 옵션이 없습니다: #{error.key}"
    end

    def run_event(options)
      parser(options).tap do |cli|
        cli.on("--case ID") { |value| options[:case_id] = value }
        cli.on("--name NAME") { |value| options[:name] = value }
        cli.on("--category CATEGORY") { |value| options[:category] = value }
        cli.on("--duration-seconds N", Integer) { |value| options[:duration_seconds] = value }
        cli.on("--rule RULE") { |value| options[:rule] = value }
        cli.on("--outcome OUTCOME") { |value| options[:outcome] = value }
      end.parse!(@argv)
      pilot(options).record(
        case_id: options.fetch(:case_id),
        name: options.fetch(:name),
        category: options[:category],
        duration_seconds: options[:duration_seconds],
        rule: options[:rule],
        outcome: options[:outcome]
      )
    rescue KeyError => error
      raise EvaluationError, "필수 event 옵션이 없습니다: #{error.key}"
    end

    def run_report(options)
      parser(options).parse!(@argv)
      @out.puts(pilot(options).report)
    end

    def parser(options)
      OptionParser.new do |cli|
        cli.on("--root PATH") { |value| options[:root] = value }
      end
    end

    def pilot(options)
      Pilot.new(root: options.fetch(:root))
    end

    def default_root
      Pathname.new(__dir__).join("../../Evaluations").expand_path
    end

    def usage
      "usage: runtime-evaluation.rb <init|active|start|event|report> [options]"
    end
  end
end

exit RuntimeEvaluation::CLI.new(ARGV).run if $PROGRAM_NAME == __FILE__
