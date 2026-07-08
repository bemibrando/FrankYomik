# Frank Yomik — furigana reader, fully in Docker (server stack + GUI).
#   make setup   configure the environment (build all images)
#   make run     run the app (then open http://localhost:6080/vnc.html)

COMPOSE := docker compose -p frank -f docker-compose.furigana.yml

.DEFAULT_GOAL := help
.PHONY: help setup up run down stop logs ps clean

help:
	@echo "Frank Yomik (Docker) — furigana reader"
	@echo ""
	@echo "  make setup   Build all images (server + GUI). Run once; GUI build is slow."
	@echo "  make run     Start everything, then open http://localhost:6080/vnc.html"
	@echo "  make down    Stop and remove containers"
	@echo "  make logs    Follow the worker log (model loading, job processing)"
	@echo "  make ps      Show container status"
	@echo "  make clean   Remove containers, images and volumes"

setup:
	$(COMPOSE) build

run up:
	@mkdir -p .frank-appdata
	-@docker rm -f frank_app >/dev/null 2>&1 || true
	$(COMPOSE) up -d
	@echo ""
	@echo ">> Open http://localhost:6080/vnc.html  ->  Local folder (furigana)  ->  /data/adult"

down stop:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f worker

ps:
	$(COMPOSE) ps

clean:
	$(COMPOSE) down -v --rmi local
