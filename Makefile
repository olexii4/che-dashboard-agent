IMAGE ?= quay.io/oorel/dashboard-agent
TAG ?= dev

.PHONY: build push run test clean

build:
	podman build -f dockerfiles/Dockerfile -t $(IMAGE):$(TAG) .

push:
	podman push $(IMAGE):$(TAG)

run:
	podman run -it --rm \
		-e ANTHROPIC_API_KEY \
		-p 8080:8080 \
		$(IMAGE):$(TAG)

test: build
	@echo "Smoke test: starting container..."
	@CID=$$(podman run -d --rm -p 8080:8080 $(IMAGE):$(TAG)) && \
		sleep 3 && \
		if curl -sf http://localhost:8080/ > /dev/null 2>&1; then \
			echo "PASS: ttyd responding on port 8080"; \
		else \
			echo "FAIL: ttyd not responding"; \
		fi; \
		podman stop $$CID > /dev/null 2>&1 || true

clean:
	podman rmi $(IMAGE):$(TAG) 2>/dev/null || true
