#!/bin/bash
set -euo pipefail

# =============================================================================
# Zupee Claw - Model Benchmark Script
# Tests Ollama models for latency, throughput, and quality on your hardware.
# Helps pick the best model for your laptop configuration.
#
# Usage:
#   ./bin/benchmark-models.sh                    # Benchmark all candidate models
#   ./bin/benchmark-models.sh qwen3.5:4b         # Benchmark a specific model
#   ./bin/benchmark-models.sh --installed         # Benchmark only installed models
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ENV_FILE not needed directly — models are tested via Docker API

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

# --- Configuration -----------------------------------------------------------

OLLAMA_CONTAINER="zupee-ollama"
CLAW_CONTAINER="zupee-claw"

# Detect Ollama mode from .env
ENV_FILE="$SCRIPT_DIR/../.env"
OLLAMA_MODE=$(grep '^OLLAMA_MODE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
OLLAMA_MODE="${OLLAMA_MODE:-auto}"
if [[ "$OLLAMA_MODE" == "auto" ]]; then
    [[ "$(uname)" == "Darwin" ]] && OLLAMA_MODE="native" || OLLAMA_MODE="docker"
fi

if [[ "$OLLAMA_MODE" == "native" ]]; then
    OLLAMA_URL="http://localhost:11434"
else
    OLLAMA_URL="http://ollama:11434"
fi

# Models to benchmark (id:memory_gib)
CANDIDATE_MODELS=(
    "qwen3:8b:8"
    "qwen3.5:1.7b:3"
    "qwen3.5:4b:8"
    "qwen3.5:9b:10"
    "llama3.1:8b:8"
    "mistral:7b:8"
    "codellama:7b:8"
)

# Test prompts and quality checks — using functions for Bash 3 compatibility
get_prompt() {
    case "$1" in
        short)     echo "Say hello in one sentence." ;;
        medium)    echo "Explain what a Docker container is and how it differs from a virtual machine. Keep it under 200 words." ;;
        coding)    echo "Write a Python function that takes a list of integers and returns the two numbers that add up to a target sum. Include type hints." ;;
        reasoning) echo "A farmer has 17 sheep. All but 9 run away. How many sheep does the farmer have left? Explain your reasoning step by step." ;;
    esac
}

get_quality_pattern() {
    case "$1" in
        short)     echo "hello|hi|hey|greetings" ;;
        reasoning) echo "9" ;;
        coding)    echo "def " ;;
        *)         echo "" ;;
    esac
}

PROMPT_TYPES="short medium coding reasoning"

# Number of runs per prompt for averaging
RUNS_PER_PROMPT=3

# Timeout per request (seconds)
REQUEST_TIMEOUT=120

# --- Helpers -----------------------------------------------------------------

ollama_exec() {
    if [[ "$OLLAMA_MODE" == "native" ]]; then
        # Clear OLLAMA_HOST — .env sets it to host.docker.internal (for containers),
        # but the native ollama CLI needs localhost (its default).
        env -u OLLAMA_HOST "$@" 2>/dev/null
    else
        docker exec "$OLLAMA_CONTAINER" "$@" 2>/dev/null
    fi
}

claw_exec() {
    docker exec "$CLAW_CONTAINER" "$@" 2>/dev/null
}

check_prerequisites() {
    if [[ "$OLLAMA_MODE" == "native" ]]; then
        if ! command -v ollama &>/dev/null; then
            error "Ollama not installed. Install from https://ollama.com/download"
            exit 1
        fi
        if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
            error "Ollama not running. Start with: ollama serve"
            exit 1
        fi
    else
        if ! docker ps --format '{{.Names}}' | grep -q "$OLLAMA_CONTAINER"; then
            error "Ollama container ($OLLAMA_CONTAINER) is not running."
            echo "  Run: ./setup.sh"
            exit 1
        fi
    fi
    # Check jq is available on host
    if ! command -v jq &>/dev/null; then
        error "jq is required. Install: brew install jq / apt install jq"
        exit 1
    fi
}

get_system_info() {
    local cpus mem_mb
    cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "?")
    mem_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || \
        sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1048576)}' || echo "?")

    echo "  System CPUs:       $cpus"
    echo "  System RAM:        ${mem_mb} MB"
    echo "  Ollama mode:       $OLLAMA_MODE"

    if [[ "$OLLAMA_MODE" == "native" ]]; then
        local gpu
        gpu=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Chipset Model" | sed 's/.*: //' || echo "unknown")
        local gpu_cores
        gpu_cores=$(system_profiler SPDisplaysDataType 2>/dev/null | grep "Total Number of Cores" | sed 's/.*: //' || echo "?")
        echo "  GPU:               $gpu (${gpu_cores} cores)"
        echo "  Ollama:            native (Metal GPU, full system resources)"
    else
        local docker_mem_bytes docker_mem_gb
        docker_mem_bytes=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
        docker_mem_gb=$(awk "BEGIN {printf \"%.1f\", $docker_mem_bytes / 1073741824}")

        local ollama_mem_bytes ollama_mem_gb ollama_cpus_nano ollama_cpus_fmt
        ollama_mem_bytes=$(docker inspect --format='{{.HostConfig.Memory}}' "$OLLAMA_CONTAINER" 2>/dev/null || echo "0")
        ollama_mem_gb=$(awk "BEGIN {printf \"%.1f\", $ollama_mem_bytes / 1073741824}")
        ollama_cpus_nano=$(docker inspect --format='{{.HostConfig.NanoCpus}}' "$OLLAMA_CONTAINER" 2>/dev/null || echo "0")
        ollama_cpus_fmt=$(awk "BEGIN {printf \"%.1f\", $ollama_cpus_nano / 1000000000}")

        echo "  Docker memory:     ${docker_mem_gb} GiB"
        echo "  Ollama:            Docker (CPU only, ${ollama_mem_gb} GiB, ${ollama_cpus_fmt} CPUs)"
    fi
}

get_installed_models() {
    local output
    output=$(ollama_exec ollama list 2>/dev/null || true)
    echo "$output" | tail -n +2 | awk '{print $1}'
}

is_model_installed() {
    local model="$1"
    local output
    output=$(ollama_exec ollama list 2>/dev/null || true)
    echo "$output" | grep -q "^${model}"
}

get_model_size() {
    local model="$1"
    local output
    output=$(ollama_exec ollama list 2>/dev/null || true)
    echo "$output" | grep "^${model}" | awk '{print $3, $4}'
}

# Run a single inference and return JSON with timing data
run_inference() {
    local model="$1"
    local prompt="$2"
    local think="${3:-false}"

    local payload
    payload="{
        \"model\": \"$model\",
        \"messages\": [{\"role\": \"user\", \"content\": $(echo "$prompt" | jq -Rs .)}],
        \"stream\": false,
        \"think\": $think,
        \"options\": {\"num_ctx\": 4096}
    }"

    local result
    if [[ "$OLLAMA_MODE" == "native" ]]; then
        result=$(curl -s --max-time "$REQUEST_TIMEOUT" \
            "${OLLAMA_URL}/api/chat" -d "$payload" 2>/dev/null)
    else
        result=$(claw_exec curl -s --max-time "$REQUEST_TIMEOUT" \
            "${OLLAMA_URL}/api/chat" -d "$payload" 2>/dev/null)
    fi

    if [[ -z "$result" ]]; then
        echo '{"error": "timeout"}'
        return 1
    fi

    echo "$result"
}

# Extract metrics from inference result
extract_metrics() {
    local result="$1"

    local total_sec load_sec prompt_eval_sec eval_sec
    local eval_count prompt_count tokens_per_sec
    local content thinking done_reason

    if echo "$result" | jq -e '.error' &>/dev/null; then
        echo "ERROR:$(echo "$result" | jq -r '.error // "unknown"')"
        return 1
    fi

    total_sec=$(echo "$result" | jq -r '(.total_duration // 0) / 1e9')
    load_sec=$(echo "$result" | jq -r '(.load_duration // 0) / 1e9')
    prompt_eval_sec=$(echo "$result" | jq -r '(.prompt_eval_duration // 0) / 1e9')
    eval_sec=$(echo "$result" | jq -r '(.eval_duration // 0) / 1e9')
    eval_count=$(echo "$result" | jq -r '.eval_count // 0')
    prompt_count=$(echo "$result" | jq -r '.prompt_eval_count // 0')
    tokens_per_sec=$(echo "$result" | jq -r 'if .eval_duration > 0 then (.eval_count / .eval_duration * 1e9) else 0 end')
    content=$(echo "$result" | jq -r '.message.content // ""')
    thinking=$(echo "$result" | jq -r '.message.thinking // ""')
    done_reason=$(echo "$result" | jq -r '.done_reason // "unknown"')

    local thinking_tokens=0
    if [[ -n "$thinking" ]] && [[ "$thinking" != "null" ]]; then
        # Rough estimate: ~4 chars per token
        thinking_tokens=$(( ${#thinking} / 4 ))
    fi

    printf "%s|%s|%s|%s|%d|%d|%s|%d|%s|%s" \
        "$total_sec" "$load_sec" "$prompt_eval_sec" "$eval_sec" \
        "$eval_count" "$prompt_count" "$tokens_per_sec" \
        "$thinking_tokens" "$done_reason" "$content"
}

# --- Benchmark Functions -----------------------------------------------------

benchmark_model() {
    local model="$1"
    local model_mem="${2:-?}"

    header "Benchmarking: $model (requires ~${model_mem}G)"

    # Check if model is installed
    if ! is_model_installed "$model"; then
        warn "Model $model not installed. Skipping."
        if [[ "$OLLAMA_MODE" == "native" ]]; then
            echo "  Pull with: ollama pull $model"
        else
            echo "  Pull with: docker exec $OLLAMA_CONTAINER ollama pull $model"
        fi
        echo ""
        return 1
    fi

    local model_size
    model_size=$(get_model_size "$model")
    echo -e "  ${DIM}Disk size: ${model_size}${NC}"
    echo ""

    # Cold start test (unload model first)
    echo -e "  ${BOLD}Cold start test${NC} (first load)..."
    ollama_exec ollama stop "$model" &>/dev/null || true
    sleep 1

    local cold_result
    cold_result=$(run_inference "$model" "Say hi." false)
    if echo "$cold_result" | jq -e '.done' &>/dev/null; then
        local cold_total cold_load
        cold_total=$(echo "$cold_result" | jq -r '(.total_duration // 0) / 1e9' | xargs printf "%.2f")
        cold_load=$(echo "$cold_result" | jq -r '(.load_duration // 0) / 1e9' | xargs printf "%.2f")
        echo -e "  ${GREEN}✓${NC} Cold start: ${cold_total}s total (${cold_load}s model load)"
    else
        local err
        err=$(echo "$cold_result" | jq -r '.error // "timeout/unknown"')
        error "Cold start failed: $err"
        echo ""
        return 1
    fi

    # Per-prompt benchmarks
    local all_tok_rates=()
    local all_latencies=()
    local quality_pass=0
    local quality_total=0

    for ptype in $PROMPT_TYPES; do
        local prompt
        prompt=$(get_prompt "$ptype")
        echo ""
        echo -e "  ${BOLD}Prompt: ${ptype}${NC}"

        local total_tok_rate=0
        local total_latency=0
        local total_ttft=0
        local total_thinking_tokens=0
        local best_content=""
        local run_count=0

        for run in $(seq 1 "$RUNS_PER_PROMPT"); do
            local result
            result=$(run_inference "$model" "$prompt" false)

            if ! echo "$result" | jq -e '.done' &>/dev/null; then
                local err
                err=$(echo "$result" | jq -r '.error // "timeout"')
                echo -e "    Run $run: ${RED}FAILED${NC} ($err)"
                continue
            fi

            local total_sec eval_sec eval_count tok_rate thinking_tokens ttft
            total_sec=$(echo "$result" | jq -r '(.total_duration // 0) / 1e9')
            eval_sec=$(echo "$result" | jq -r '(.eval_duration // 0) / 1e9')
            eval_count=$(echo "$result" | jq -r '.eval_count // 0')
            tok_rate=$(echo "$result" | jq -r 'if .eval_duration > 0 then (.eval_count / .eval_duration * 1e9) else 0 end')
            ttft=$(echo "$result" | jq -r '((.prompt_eval_duration // 0) + (.load_duration // 0)) / 1e9')

            local thinking
            thinking=$(echo "$result" | jq -r '.message.thinking // ""')
            thinking_tokens=0
            if [[ -n "$thinking" ]] && [[ "$thinking" != "null" ]] && [[ ${#thinking} -gt 0 ]]; then
                thinking_tokens=$(( ${#thinking} / 4 ))
            fi

            total_tok_rate=$(awk "BEGIN {print $total_tok_rate + $tok_rate}")
            total_latency=$(awk "BEGIN {print $total_latency + $total_sec}")
            total_ttft=$(awk "BEGIN {print $total_ttft + $ttft}")
            total_thinking_tokens=$(( total_thinking_tokens + thinking_tokens ))
            run_count=$(( run_count + 1 ))

            local content
            content=$(echo "$result" | jq -r '.message.content // ""')
            if [[ -z "$best_content" ]]; then
                best_content="$content"
            fi

            local total_fmt tok_fmt
            total_fmt=$(printf "%.1f" "$total_sec")
            tok_fmt=$(printf "%.1f" "$tok_rate")
            local think_info=""
            if [[ $thinking_tokens -gt 0 ]]; then
                think_info=" ${DIM}(~${thinking_tokens} thinking tokens)${NC}"
            fi
            echo -e "    Run $run: ${total_fmt}s, ${eval_count} tokens, ${tok_fmt} tok/s${think_info}"
        done

        if [[ $run_count -eq 0 ]]; then
            echo -e "    ${RED}All runs failed${NC}"
            continue
        fi

        # Averages
        local avg_tok_rate avg_latency avg_ttft avg_thinking
        avg_tok_rate=$(awk "BEGIN {printf \"%.1f\", $total_tok_rate / $run_count}")
        avg_latency=$(awk "BEGIN {printf \"%.2f\", $total_latency / $run_count}")
        avg_ttft=$(awk "BEGIN {printf \"%.2f\", $total_ttft / $run_count}")
        avg_thinking=$(( total_thinking_tokens / run_count ))

        echo -e "    ${CYAN}Avg: ${avg_latency}s latency, ${avg_tok_rate} tok/s, ${avg_ttft}s TTFT${NC}"
        if [[ $avg_thinking -gt 0 ]]; then
            echo -e "    ${YELLOW}⚠ Model uses thinking mode (~${avg_thinking} hidden tokens/request)${NC}"
        fi

        all_tok_rates+=("$avg_tok_rate")
        all_latencies+=("$avg_latency")

        # Quality check
        local quality_pattern
        quality_pattern=$(get_quality_pattern "$ptype")
        if [[ -n "$quality_pattern" ]]; then
            quality_total=$(( quality_total + 1 ))
            if echo "$best_content" | grep -qiE "$quality_pattern"; then
                quality_pass=$(( quality_pass + 1 ))
                echo -e "    Quality: ${GREEN}PASS${NC}"
            else
                echo -e "    Quality: ${RED}FAIL${NC} (expected pattern: $quality_pattern)"
            fi
        fi
    done

    # Memory usage
    echo ""
    local mem_usage
    if [[ "$OLLAMA_MODE" == "native" ]]; then
        mem_usage=$(ps -o rss= -p "$(pgrep -f 'ollama' | head -1)" 2>/dev/null | awk '{printf "%.1f GiB", $1/1048576}')
    else
        mem_usage=$(docker stats --no-stream --format '{{.MemUsage}}' "$OLLAMA_CONTAINER" 2>/dev/null)
    fi
    echo -e "  Memory usage: $mem_usage"

    # Summary for this model
    if [[ ${#all_tok_rates[@]} -gt 0 ]]; then
        local sum_rate=0 sum_lat=0
        for r in "${all_tok_rates[@]}"; do sum_rate=$(awk "BEGIN {print $sum_rate + $r}"); done
        for l in "${all_latencies[@]}"; do sum_lat=$(awk "BEGIN {print $sum_lat + $l}"); done
        local overall_rate overall_lat
        overall_rate=$(awk "BEGIN {printf \"%.1f\", $sum_rate / ${#all_tok_rates[@]}}")
        overall_lat=$(awk "BEGIN {printf \"%.2f\", $sum_lat / ${#all_latencies[@]}}")

        echo ""
        echo -e "  ${BOLD}── Summary ──${NC}"
        echo -e "  Avg throughput:  ${BOLD}${overall_rate} tok/s${NC}"
        echo -e "  Avg latency:     ${BOLD}${overall_lat}s${NC}"
        echo -e "  Quality:         ${quality_pass}/${quality_total} checks passed"

        # Rating
        local rating=""
        local rate_num=${overall_rate%.*}
        if [[ ${rate_num:-0} -ge 30 ]]; then
            rating="${GREEN}★★★ Excellent${NC}"
        elif [[ ${rate_num:-0} -ge 15 ]]; then
            rating="${GREEN}★★☆ Good${NC}"
        elif [[ ${rate_num:-0} -ge 8 ]]; then
            rating="${YELLOW}★☆☆ Usable${NC}"
        else
            rating="${RED}☆☆☆ Too slow${NC}"
        fi
        echo -e "  Rating:          ${rating}"

        # Store result for comparison
        echo "${model}|${model_mem}|${overall_rate}|${overall_lat}|${quality_pass}/${quality_total}|${model_size}" >> "$RESULTS_FILE"
    fi

    echo ""
}

# --- Main --------------------------------------------------------------------

main() {
    header "Zupee Claw - Model Benchmark"
    echo ""
    echo "  Tests models for latency, throughput, and quality on your hardware."
    echo "  Each prompt is run ${RUNS_PER_PROMPT} times and averaged."
    echo ""

    check_prerequisites

    header "Hardware"
    get_system_info
    echo ""

    # Results file for comparison table
    RESULTS_FILE=$(mktemp /tmp/claw-benchmark-XXXXXX.txt)
    trap 'rm -f "$RESULTS_FILE"' EXIT

    # Determine which models to test
    local models_to_test=()

    if [[ "${1:-}" == "--installed" ]]; then
        # Only test installed models
        while IFS= read -r model; do
            for candidate in "${CANDIDATE_MODELS[@]}"; do
                local cid cmem
                cid="${candidate%%:*}"
                # Extract model id (first two colon-separated fields)
                cid=$(echo "$candidate" | awk -F: '{print $1":"$2}')
                cmem=$(echo "$candidate" | awk -F: '{print $NF}')
                if [[ "$model" == "$cid" ]]; then
                    models_to_test+=("$cid:$cmem")
                    break
                fi
            done
        done < <(get_installed_models)

        if [[ ${#models_to_test[@]} -eq 0 ]]; then
            error "No candidate models installed. Pull some first:"
            for c in "${CANDIDATE_MODELS[@]}"; do
                local cid
                cid=$(echo "$c" | awk -F: '{print $1":"$2}')
                echo "  docker exec $OLLAMA_CONTAINER ollama pull $cid"
            done
            exit 1
        fi
    elif [[ -n "${1:-}" ]] && [[ "${1:-}" != "--"* ]]; then
        # Specific model
        local specific="$1"
        local mem="?"
        for candidate in "${CANDIDATE_MODELS[@]}"; do
            local cid
            cid=$(echo "$candidate" | awk -F: '{print $1":"$2}')
            if [[ "$specific" == "$cid" ]]; then
                mem=$(echo "$candidate" | awk -F: '{print $NF}')
                break
            fi
        done
        models_to_test+=("$specific:$mem")
    else
        # All candidate models
        for candidate in "${CANDIDATE_MODELS[@]}"; do
            local cid cmem
            cid=$(echo "$candidate" | awk -F: '{print $1":"$2}')
            cmem=$(echo "$candidate" | awk -F: '{print $NF}')
            models_to_test+=("$cid:$cmem")
        done
    fi

    info "Models to benchmark: ${#models_to_test[@]}"
    for m in "${models_to_test[@]}"; do
        local mid mmem
        mid="${m%:*}"
        mmem="${m##*:}"
        local installed=""
        if is_model_installed "$mid"; then
            installed="${GREEN}(installed)${NC}"
        else
            installed="${DIM}(not installed)${NC}"
        fi
        echo -e "  - $mid (${mmem}G) $installed"
    done

    # Run benchmarks
    for m in "${models_to_test[@]}"; do
        local mid mmem
        mid="${m%:*}"
        mmem="${m##*:}"
        benchmark_model "$mid" "$mmem" || true
    done

    # --- Comparison Table ---
    if [[ -s "$RESULTS_FILE" ]]; then
        header "Comparison"
        echo ""
        printf "  ${BOLD}%-20s %6s %10s %10s %9s %10s${NC}\n" \
            "MODEL" "MEM" "TOK/S" "LATENCY" "QUALITY" "DISK"
        printf "  %-20s %6s %10s %10s %9s %10s\n" \
            "────────────────────" "──────" "──────────" "──────────" "─────────" "──────────"

        while IFS='|' read -r model mem rate lat qual size; do
            local rate_num=${rate%.*}
            local color="$NC"
            if [[ ${rate_num:-0} -ge 30 ]]; then color="$GREEN"
            elif [[ ${rate_num:-0} -ge 15 ]]; then color="$GREEN"
            elif [[ ${rate_num:-0} -ge 8 ]]; then color="$YELLOW"
            else color="$RED"
            fi

            printf "  %-20s %5sG ${color}%9s${NC} %9ss %9s %10s\n" \
                "$model" "$mem" "${rate} t/s" "$lat" "$qual" "$size"
        done < "$RESULTS_FILE"

        echo ""

        # Recommendation
        local best_model
        best_model=$(sort -t'|' -k3 -rn "$RESULTS_FILE" | head -1)
        if [[ -n "$best_model" ]]; then
            local bname brate bqual
            bname=$(echo "$best_model" | cut -d'|' -f1)
            brate=$(echo "$best_model" | cut -d'|' -f3)
            bqual=$(echo "$best_model" | cut -d'|' -f5)
            echo -e "  ${GREEN}${BOLD}Recommendation: $bname${NC}"
            echo -e "  ${brate} tok/s, quality ${bqual}"
            echo ""
            echo "  To use this model, set in .env:"
            echo "    OLLAMA_MODEL=$bname"
            echo "  Then run: ./setup.sh"
        fi
    else
        warn "No benchmark results collected."
    fi

    echo ""
}

main "$@"
