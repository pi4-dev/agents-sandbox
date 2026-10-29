#!/bin/sh

docker compose up -d 
docker compose exec ae-squid squid -k reconfigure

docker compose exec ae-claude-main claude --dangerously-skip-permissions --remote-control "main"



# headless
# docker compose exec -T ae-claude sh -c 'cd /workspace/repo-a && claude -p "Przejrzyj zmiany z ostatnich 24h i wypisz potencjalne bledy" --output-format json' > review.json


