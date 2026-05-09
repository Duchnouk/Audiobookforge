#!/bin/bash
# ============================================
# Script de lancement d'AudiobookForge
# ============================================
# Usage : ./start.sh
# ============================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        AudiobookForge - Lancement         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# ============================================
# 1. Vérifier les prérequis
# ============================================
echo -e "${YELLOW}🔍 Vérification des prérequis...${NC}"

# Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}❌ Docker n'est pas installé${NC}"
    echo "   Installe Docker Desktop : https://www.docker.com/products/docker-desktop/"
    exit 1
fi
echo -e "${GREEN}  ✅ Docker${NC}"

# Ollama
if ! command -v ollama &> /dev/null; then
    echo -e "${RED}❌ Ollama n'est pas installé${NC}"
    echo "   brew install ollama"
    exit 1
fi
echo -e "${GREEN}  ✅ Ollama${NC}"

# ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${RED}❌ ffmpeg n'est pas installé${NC}"
    echo "   brew install ffmpeg"
    exit 1
fi
echo -e "${GREEN}  ✅ ffmpeg${NC}"

# Python venv
if [ ! -d "${SCRIPT_DIR}/backend/venv" ]; then
    echo -e "${YELLOW}📦 Création de l'environnement Python...${NC}"
    cd "${SCRIPT_DIR}/backend"
    python3 -m venv venv
    source venv/bin/activate
    pip install -r requirements.txt
    pip install httpx
    deactivate
    cd "${SCRIPT_DIR}"
fi
echo -e "${GREEN}  ✅ Python venv${NC}"

# Modèle Ollama
echo -e "${YELLOW}🔍 Vérification du modèle Qwen3...${NC}"
if ! ollama list 2>/dev/null | grep -q "qwen3"; then
    echo -e "${YELLOW}📥 Téléchargement de Qwen3 30B (premier lancement seulement)...${NC}"
    ollama pull qwen3:30b
fi
echo -e "${GREEN}  ✅ Modèle Qwen3${NC}"

echo ""

# ============================================
# 2. Lancer les services Docker
# ============================================
echo -e "${YELLOW}🐳 Démarrage des containers Docker...${NC}"
cd "${SCRIPT_DIR}"

# Vérifier si Docker Desktop est en marche
if ! docker info &>/dev/null; then
    echo -e "${RED}❌ Docker Desktop n'est pas en cours d'exécution${NC}"
    echo "   Lance Docker Desktop depuis le dossier Applications"
    exit 1
fi

docker compose up -d --build 2>&1 || docker-compose up -d --build 2>&1
echo -e "${GREEN}✅ Containers Docker démarrés${NC}"
echo ""

# ============================================
# 3. Lancer Ollama (si pas déjà en cours)
# ============================================
echo -e "${YELLOW}🦙 Démarrage d'Ollama...${NC}"
if pgrep -x "ollama" > /dev/null; then
    echo -e "${GREEN}  ✅ Ollama déjà en cours${NC}"
else
    ollama serve &
    sleep 2
    echo -e "${GREEN}  ✅ Ollama démarré${NC}"
fi
echo ""

# ============================================
# 4. Vérifier que tout est OK
# ============================================
echo -e "${YELLOW}🔍 Vérification des services...${NC}"
sleep 2

# Vérifier l'API backend
if curl -s http://localhost:8000/health > /dev/null 2>&1; then
    echo -e "${GREEN}  ✅ API backend (port 8000)${NC}"
else
    echo -e "${RED}  ❌ API backend inaccessible${NC}"
fi

# Vérifier Ollama
if curl -s http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo -e "${GREEN}  ✅ Ollama (port 11434)${NC}"
else
    echo -e "${RED}  ❌ Ollama inaccessible${NC}"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    AudiobookForge est prêt !              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "📂 Projet : ${SCRIPT_DIR}"
echo -e "🔗 API     : http://localhost:8000/docs"
echo -e "🦙 Ollama  : http://localhost:11434"
echo ""
echo -e "Pour ouvrir dans Xcode :"
echo -e "  ${BLUE}open ${SCRIPT_DIR}/Package.swift${NC}"
echo ""
echo -e "Pour arrêter les containers :"
echo -e "  ${BLUE}cd ${SCRIPT_DIR} && docker compose down${NC}"
