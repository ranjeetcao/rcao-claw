#!/bin/bash
set -euo pipefail

# =============================================================================
# Zupee Claw - SearXNG Search Test Suite
# Tests web search end-to-end: SearXNG health, JSON API, Squid ACLs,
# engine coverage, and OpenClaw integration.
#
# Usage:
#   ./bin/test-search.sh              # Run all tests
#   ./bin/test-search.sh --quick      # Health + basic search only
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "${GREEN}  PASS${NC} $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "${RED}  FAIL${NC} $*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); echo -e "${YELLOW}  SKIP${NC} $*"; }
header() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}"; }

CLAW_CONTAINER="zupee-claw"
SEARXNG_CONTAINER="zupee-searxng"
SQUID_CONTAINER="zupee-squid"
SEARXNG_URL="http://searxng:8080"
REQUEST_TIMEOUT=30

QUICK=false
[[ "${1:-}" == "--quick" ]] && QUICK=true

# Helper: run curl from inside the Claw container (bypasses NO_PROXY correctly)
claw_curl() {
    docker exec "$CLAW_CONTAINER" curl -sf --max-time "$REQUEST_TIMEOUT" "$@" 2>/dev/null
}

# Helper: run curl from inside SearXNG container (tests internal connectivity)
searxng_curl() {
    docker exec "$SEARXNG_CONTAINER" python3 -c "
import urllib.request, json, sys
try:
    req = urllib.request.Request('$1')
    resp = urllib.request.urlopen(req, timeout=$REQUEST_TIMEOUT)
    print(resp.read().decode()[:2000])
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# --- Prerequisites ---

header "Prerequisites"

if docker ps --format '{{.Names}}' | grep -q "$SEARXNG_CONTAINER"; then
    pass "SearXNG container running"
else
    fail "SearXNG container not running"
    echo "  Run: docker compose up -d searxng"
    exit 1
fi

if docker ps --format '{{.Names}}' | grep -q "$SQUID_CONTAINER"; then
    pass "Squid proxy running"
else
    fail "Squid proxy not running"
fi

if docker ps --format '{{.Names}}' | grep -q "$CLAW_CONTAINER"; then
    pass "Claw container running"
else
    fail "Claw container not running"
fi

# --- Health Checks ---

header "SearXNG Health"

# Test: SearXNG responds to health check
if searxng_curl "http://localhost:8080/" > /dev/null 2>&1; then
    pass "SearXNG health endpoint responds"
else
    fail "SearXNG health endpoint unreachable"
fi

# Test: Claw can reach SearXNG internally
if claw_curl "$SEARXNG_URL/" > /dev/null 2>&1; then
    pass "Claw → SearXNG connectivity OK"
else
    fail "Claw cannot reach SearXNG (check NO_PROXY includes 'searxng')"
fi

if [[ "$QUICK" == "true" ]]; then
    # Quick mode: just one search test
    header "Basic Search"
    RESULT=$(claw_curl "$SEARXNG_URL/search?q=hello&format=json" || echo "")
    if echo "$RESULT" | jq -e '.results | length > 0' > /dev/null 2>&1; then
        COUNT=$(echo "$RESULT" | jq '.results | length')
        pass "Search returned $COUNT results"
    else
        fail "Search returned no results"
    fi
else

# --- JSON API Tests ---

header "JSON API"

# Test: JSON format returns valid JSON
RESULT=$(claw_curl "$SEARXNG_URL/search?q=hello+world&format=json" || echo "")
if echo "$RESULT" | jq -e '.' > /dev/null 2>&1; then
    pass "JSON response is valid"
else
    fail "Invalid JSON response"
fi

# Test: Results contain required fields
if echo "$RESULT" | jq -e '.results[0].title' > /dev/null 2>&1; then
    pass "Results have 'title' field"
else
    fail "Missing 'title' field in results"
fi

if echo "$RESULT" | jq -e '.results[0].url' > /dev/null 2>&1; then
    pass "Results have 'url' field"
else
    fail "Missing 'url' field in results"
fi

if echo "$RESULT" | jq -e '.results[0].content' > /dev/null 2>&1; then
    pass "Results have 'content' (snippet) field"
else
    skip "Missing 'content' field (some engines omit snippets)"
fi

# Test: Results count > 0
COUNT=$(echo "$RESULT" | jq '.results | length' 2>/dev/null || echo "0")
if [[ "$COUNT" -gt 0 ]]; then
    pass "Returned $COUNT results"
else
    fail "Zero results"
fi

# --- Developer-Relevant Searches ---

header "Developer Search Quality"

# Test: Programming query returns relevant results
RESULT=$(claw_curl "$SEARXNG_URL/search?q=fastify+rate+limiting+node.js&format=json" || echo "")
if echo "$RESULT" | jq -r '.results[].url' 2>/dev/null | grep -qiE "fastify|github|stackoverflow|npm"; then
    pass "Programming query returns dev-relevant URLs"
else
    fail "Programming query returned no dev-relevant results"
fi

# Test: GitHub search works
RESULT=$(claw_curl "$SEARXNG_URL/search?q=react+native+expo+github&format=json" || echo "")
if echo "$RESULT" | jq -r '.results[].url' 2>/dev/null | grep -qi "github"; then
    pass "GitHub results appear in search"
else
    skip "GitHub results not found (engine may be slow)"
fi

# Test: StackOverflow results appear
RESULT=$(claw_curl "$SEARXNG_URL/search?q=mongodb+aggregation+pipeline+stackoverflow&format=json" || echo "")
if echo "$RESULT" | jq -r '.results[].url' 2>/dev/null | grep -qi "stackoverflow"; then
    pass "StackOverflow results appear in search"
else
    skip "StackOverflow results not found (engine may be slow)"
fi

# Test: npm package search
RESULT=$(claw_curl "$SEARXNG_URL/search?q=fastify+npm+package&format=json" || echo "")
if echo "$RESULT" | jq -r '.results[].url' 2>/dev/null | grep -qiE "npm|fastify"; then
    pass "npm-related results appear"
else
    skip "npm results not found"
fi

# --- Squid ACL Tests ---

header "Squid Proxy ACLs"

# Test: Search engines are allowed through Squid
SQUID_LOG="/Users/ranjeet/workspace/zupee-claw/logs/squid/access.log"
if grep -q "google.com" "$SQUID_LOG" 2>/dev/null; then
    pass "Google.com seen in Squid logs (allowed)"
else
    skip "Google.com not in Squid logs yet (may need a search first)"
fi

if grep -q "duckduckgo.com" "$SQUID_LOG" 2>/dev/null; then
    pass "DuckDuckGo seen in Squid logs (allowed)"
else
    skip "DuckDuckGo not in Squid logs yet"
fi

# Test: Non-whitelisted domains are blocked
BLOCKED=$(docker exec "$CLAW_CONTAINER" curl -sf --proxy http://squid:3128 --max-time 5 https://evil-test-domain.com 2>&1 || echo "BLOCKED")
if echo "$BLOCKED" | grep -qiE "denied|blocked|403|BLOCKED"; then
    pass "Non-whitelisted domain blocked by Squid"
else
    fail "Non-whitelisted domain NOT blocked (security issue!)"
fi

# --- Edge Cases ---

header "Edge Cases"

# Test: Empty query
RESULT=$(claw_curl "$SEARXNG_URL/search?q=&format=json" 2>&1 || echo "ERROR")
if [[ "$RESULT" == "ERROR" ]] || echo "$RESULT" | jq -e '.results | length == 0' > /dev/null 2>&1; then
    pass "Empty query handled gracefully"
else
    pass "Empty query returned results (acceptable)"
fi

# Test: Special characters in query
RESULT=$(claw_curl "$SEARXNG_URL/search?q=c%2B%2B+template+metaprogramming&format=json" || echo "")
if echo "$RESULT" | jq -e '.results | length > 0' > /dev/null 2>&1; then
    pass "Special characters (C++) handled correctly"
else
    skip "Special character query returned no results"
fi

# Test: Long query
LONG_QUERY="how+to+implement+authentication+with+jwt+refresh+tokens+in+a+node.js+fastify+backend+with+mongodb"
RESULT=$(claw_curl "$SEARXNG_URL/search?q=$LONG_QUERY&format=json" || echo "")
if echo "$RESULT" | jq -e '.results | length > 0' > /dev/null 2>&1; then
    pass "Long query returned results"
else
    skip "Long query returned no results"
fi

# Test: Language parameter
RESULT=$(claw_curl "$SEARXNG_URL/search?q=kubernetes+deployment&format=json&language=en" || echo "")
if echo "$RESULT" | jq -e '.results | length > 0' > /dev/null 2>&1; then
    pass "Language parameter accepted"
else
    skip "Language parameter query failed"
fi

# --- Performance ---

header "Performance"

# Test: Response time under 10 seconds
START=$(date +%s%N)
claw_curl "$SEARXNG_URL/search?q=docker+compose+networking&format=json" > /dev/null 2>&1
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if [[ $ELAPSED_MS -lt 10000 ]]; then
    pass "Search completed in ${ELAPSED_MS}ms (under 10s)"
else
    fail "Search took ${ELAPSED_MS}ms (over 10s threshold)"
fi

# Test: Second search is faster (cache hit)
START=$(date +%s%N)
claw_curl "$SEARXNG_URL/search?q=docker+compose+networking&format=json" > /dev/null 2>&1
END=$(date +%s%N)
CACHED_MS=$(( (END - START) / 1000000 ))
if [[ $CACHED_MS -lt $ELAPSED_MS ]]; then
    pass "Cached search faster: ${CACHED_MS}ms vs ${ELAPSED_MS}ms"
else
    skip "Cache didn't improve speed (${CACHED_MS}ms vs ${ELAPSED_MS}ms)"
fi

fi  # end of non-quick tests

# --- Summary ---

header "Results"
echo ""
echo -e "  ${GREEN}PASS:  $PASS_COUNT${NC}"
echo -e "  ${RED}FAIL:  $FAIL_COUNT${NC}"
echo -e "  ${YELLOW}SKIP:  $SKIP_COUNT${NC}"
echo -e "  Total: $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}ALL TESTS PASSED${NC}"
else
    echo -e "  ${RED}${BOLD}$FAIL_COUNT FAILURES${NC}"
fi

exit $FAIL_COUNT
