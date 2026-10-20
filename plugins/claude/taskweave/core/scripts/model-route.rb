#!/usr/bin/env ruby

require "json"
require "optparse"
require "pathname"

class ModelRouteError < StandardError; end

CODEX_ROUTES = {
  "terra" => { "agent_type" => "general-terra", "model" => "gpt-6.1-sol", "preferences" => %w[sol terra astra luna] },
  "luna" => { "agent_type" => "routine-luna", "model" => "gpt-6-luna", "preferences" => %w[luna terra sol astra] },
  "spark" => { "agent_type" => "ui-spark", "model" => "gpt-6-luna", "preferences" => %w[luna terra sol astra] },
  "sol" => { "agent_type" => "high-risk-sol", "model" => "gpt-6-astra", "preferences" => %w[astra sol terra luna] }
}.freeze

CLAUDE_ROUTES = {
  "terra" => { "agent_type" => "general", "model" => "sonnet" },
  "luna" => { "agent_type" => "routine", "model" => "fable" },
  "spark" => { "agent_type" => "ui-narrow", "model" => "fable" },
  "sol" => { "agent_type" => "high-risk", "model" => "opus" }
}.freeze

STAGES = {
  "planning" => %w[terra sol],
  "implementation" => %w[terra luna spark sol],
  "review" => %w[terra sol]
}.freeze

def select_codex_model(available_models, route)
  raise ModelRouteError, "현재 실행 도구의 모델 목록을 --available-model로 전달해야 합니다" if available_models.empty?

  # 역할별 선호 모델이 없어도 실행 가능한 GPT-6가 있으면 GPT-5를 제외한다.
  six = available_models.select { |name| name.match?(/\Agpt-6(?:\.\d+)*(?:-|\z)/) }
  candidates = six.empty? ? available_models.select { |name| name.match?(/\Agpt-5(?:\.\d+)*(?:-|\z)/) } : six
  raise ModelRouteError, "실행 가능한 GPT-6/GPT-5 후보가 없습니다" if candidates.empty?

  candidates.max_by do |name|
    version = name[/\Agpt-(\d+(?:\.\d+)*)/, 1].split(".").map(&:to_i)
    family = name.sub(/\Agpt-\d+(?:\.\d+)*(?:-|\z)/, "").split("-").first
    preference = route.fetch("preferences").index(family) || route.fetch("preferences").length
    [-preference, version, name]
  end
end

begin
  options = { available_models: [] }
  OptionParser.new do |parser|
    parser.on("--stage STAGE") { |value| options[:stage] = value }
    parser.on("--model MODEL") { |value| options[:model] = value }
    parser.on("--client CLIENT") { |value| options[:client] = value }
    parser.on("--runtime-root PATH") { |value| options[:runtime_root] = value }
    parser.on("--available-model MODEL") { |value| options[:available_models] << value }
  end.parse!

  stage = options[:stage].to_s
  model_key = options[:model].to_s
  client = (options[:client] || ENV.fetch("AI_RUNTIME_CLIENT", "codex")).to_s
  raise ModelRouteError, "지원하지 않는 client입니다: #{client}" unless %w[codex claude].include?(client)
  raise ModelRouteError, "지원하지 않는 stage입니다: #{stage}" unless STAGES.key?(stage)
  unless STAGES.fetch(stage).include?(model_key)
    raise ModelRouteError, "#{stage} 단계에서 사용할 수 없는 model입니다: #{model_key}"
  end

  runtime_root = Pathname.new(options[:runtime_root] || Pathname(__dir__).join("..")).expand_path.cleanpath
  route = (client == "codex" ? CODEX_ROUTES : CLAUDE_ROUTES).fetch(model_key)
  selected_model = client == "codex" ? select_codex_model(options.fetch(:available_models).uniq, route) : route.fetch("model")
  if client == "codex"
    config = runtime_root.join("agents", "#{route.fetch('agent_type')}.toml")
    raise ModelRouteError, "agent 설정이 없습니다: #{config}" unless config.file?
    values = config.read(encoding: "UTF-8").scan(/^(name|model|model_reasoning_effort)\s*=\s*"(.*)"$/).to_h
    raise ModelRouteError, "agent name 불일치: #{config}" unless values["name"] == route.fetch("agent_type")
    raise ModelRouteError, "agent model 불일치: #{config}" unless values["model"] == route.fetch("model")
    reasoning_effort = values.fetch("model_reasoning_effort")
  else
    claude_runtime = runtime_root.join("..", "..", "Claude_Code", "Runtime").cleanpath
    config = claude_runtime.join("agents", "#{route.fetch('agent_type')}.md")
    raise ModelRouteError, "Claude agent 설정이 없습니다: #{config}" unless config.file?
    frontmatter = config.read(encoding: "UTF-8")[/\A---\n(.*?)\n---/m, 1].to_s
    values = frontmatter.scan(/^(name|model):\s*(.+)$/).to_h
    raise ModelRouteError, "Claude agent name 불일치: #{config}" unless values["name"] == route.fetch("agent_type")
    raise ModelRouteError, "Claude agent model 불일치: #{config}" unless values["model"] == route.fetch("model")
    reasoning_effort = "client-default"
  end

  result = {
    "client" => client,
    "stage" => stage,
    "model_key" => model_key,
    "agent_type" => route.fetch("agent_type"),
    "model" => selected_model,
    "reasoning_effort" => reasoning_effort,
    "delegation_required" => true,
    "config" => config.to_s
  }

  if client == "codex"
    result["dispatch_attempts"] = [
      {
        "order" => 1,
        "agent_type" => route.fetch("agent_type"),
        "model" => selected_model,
        "reasoning_effort" => reasoning_effort,
        "use_when" => "custom agent type is available with the resolved model"
      },
      {
        "order" => 2,
        "agent_type" => "default",
        "model" => selected_model,
        "reasoning_effort" => reasoning_effort,
        "use_when" => "custom agent type is unavailable or its current model differs",
        "max_attempts" => 1
      }
    ]
    result["dispatch_evidence_required"] = true
  end

  puts JSON.pretty_generate(result)
rescue OptionParser::ParseError, ModelRouteError, KeyError => error
  warn "ERROR: #{error.message}"
  exit 2
end
