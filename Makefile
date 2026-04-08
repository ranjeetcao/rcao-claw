.PHONY: setup up down logs status clean health slack-test

setup:
	./setup.sh

up:
	cd docker && docker compose up -d

down:
	cd docker && docker compose down

logs:
	cd docker && docker compose logs -f

status:
	ssh openclaw-bot@localhost "service-status"

clean:
	./cleanup.sh

health:
	@echo "=== Claw ==="
	@curl -sf http://localhost:3000/health && echo " OK" || echo " FAIL"
	@echo "=== Ollama ==="
	@cd docker && docker compose exec ollama curl -sf http://localhost:11434/api/tags > /dev/null && echo " OK" || echo " FAIL"
	@echo "=== SSH Gateway ==="
	@ssh openclaw-bot@localhost "service-status" > /dev/null 2>&1 && echo " OK" || echo " FAIL"
	@echo "=== Squid Proxy ==="
	@curl -sf --proxy http://127.0.0.1:3128 https://slack.com/api/api.test > /dev/null 2>&1 && echo " OK" || echo " FAIL"

slack-test:
	@echo "=== Squid Proxy ==="
	@echo -n "  Slack allowed: "
	@curl -sf --proxy http://127.0.0.1:3128 https://slack.com/api/api.test > /dev/null 2>&1 && echo "OK" || echo "FAIL"
	@echo -n "  Non-Slack blocked: "
	@curl -sf --proxy http://127.0.0.1:3128 --max-time 5 https://google.com > /dev/null 2>&1 && echo "FAIL (should be blocked)" || echo "OK (blocked)"
	@echo "=== Container Proxy ==="
	@echo -n "  HTTPS_PROXY set: "
	@cd docker && docker compose exec openclaw printenv HTTPS_PROXY 2>/dev/null | grep -q squid && echo "OK" || echo "FAIL"
	@echo -n "  Slack via proxy: "
	@cd docker && docker compose exec openclaw curl -sf --proxy http://squid:3128 https://slack.com/api/api.test > /dev/null 2>&1 && echo "OK" || echo "FAIL"
	@echo -n "  Non-Slack blocked: "
	@cd docker && docker compose exec openclaw curl -sf --proxy http://squid:3128 --max-time 5 https://google.com > /dev/null 2>&1 && echo "FAIL (should be blocked)" || echo "OK (blocked)"
