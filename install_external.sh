#!/bin/bash
# ============================================
# Script d'installation d'AudiobookForge
# sur disque dur externe
# ============================================
# Usage :
#   1. Branche ton disque externe
#   2. ./install_external.sh /Volumes/NOM_DU_DISQUE
# ============================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     AudiobookForge - Installation         ║${NC}"
echo -e "${BLUE}║        sur disque externe                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
echo ""

# Vérifier les arguments
if [ $# -lt 1 ]; then
    echo -e "${RED}❌ Usage : $0 /Volumes/NOM_DU_DISQUE${NC}"
    echo ""
    echo "Disques disponibles :"
    ls -1 /Volumes/
    exit 1
fi

EXTERNAL_DRIVE="$1"
INSTALL_DIR="${EXTERNAL_DRIVE}/AudiobookForge"

echo -e "${YELLOW}📁 Installation dans : ${INSTALL_DIR}${NC}"
echo ""

# Vérifier que le disque est monté
if [ ! -d "$EXTERNAL_DRIVE" ]; then
    echo -e "${RED}❌ Le disque ${EXTERNAL_DRIVE} n'est pas monté${NC}"
    exit 1
fi

# ============================================
# Étape 1 : Cloner le projet
# ============================================
echo -e "${BLUE}[1/6] Clonage du projet...${NC}"
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}⚠️  Le dossier existe déjà. Mise à jour...${NC}"
    cd "$INSTALL_DIR"
    git pull
else
    git clone https://github.com/Duchnouk/Audiobookforge.git "$INSTALL_DIR"
    cd "$INSTALL_DIR"
fi
echo -e "${GREEN}✅ Projet cloné${NC}"

# ============================================
# Étape 2 : Créer les dossiers de données
# ============================================
echo -e "${BLUE}[2/6] Création des dossiers de données...${NC}"
mkdir -p "${INSTALL_DIR}/data/ollama"
mkdir -p "${INSTALL_DIR}/data/backend"
mkdir -p "${INSTALL_DIR}/models"
mkdir -p "${INSTALL_DIR}/outputs"
echo -e "${GREEN}✅ Dossiers créés${NC}"

# ============================================
# Étape 3 : Configurer docker-compose pour le disque externe
# ============================================
echo -e "${BLUE}[3/6] Configuration de Docker pour le disque externe...${NC}"
# Créer un docker-compose.override.yml qui pointe vers le disque externe
cat > "${INSTALL_DIR}/docker-compose.override.yml" << EOF
version: "3.9"

volumes:
  ollama_data:
    driver: local
    driver_opts:
      type: none
      device: "${INSTALL_DIR}/data/ollama"
      o: bind
  backend_data:
    driver: local
    driver_opts:
      type: none
      device: "${INSTALL_DIR}/data/backend"
      o: bind
EOF
echo -e "${GREEN}✅ Configuration Docker adaptée${NC}"

# ============================================
# Étape 4 : Installer Docker Desktop si nécessaire
# ============================================
echo -e "${BLUE}[4/6] Vérification de Docker...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}⚠️  Docker n'est pas installé.${NC}"
    echo -e "${YELLOW}   Télécharge Docker Desktop pour Mac :${NC}"
    echo -e "${YELLOW}   https://www.docker.com/products/docker-desktop/${NC}"
    echo -e "${YELLOW}   Installe-le puis relance ce script.${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Docker est installé${NC}"

# ============================================
# Étape 5 : Installer les dépendances macOS natives
# ============================================
echo -e "${BLUE}[5/6] Installation des dépendances macOS...${NC}"

# Homebrew
if ! command -v brew &> /dev/null; then
    echo -e "${YELLOW}⚠️  Homebrew n'est pas installé. Installation...${NC}"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${YELLOW}📦 Installation de ffmpeg...${NC}"
    brew install ffmpeg
else
    echo -e "${GREEN}✅ ffmpeg déjà installé${NC}"
fi

# Ollama (pour le LLM local)
if ! command -v ollama &> /dev/null; then
    echo -e "${YELLOW}📦 Installation de Ollama...${NC}"
    brew install ollama
else
    echo -e "${GREEN}✅ Ollama déjà installé${NC}"
fi

# Python venv
echo -e "${YELLOW}📦 Configuration de l'environnement Python...${NC}"
cd "${INSTALL_DIR}/backend"
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
pip install httpx
deactivate

echo -e "${GREEN}✅ Dépendances installées${NC}"

# ============================================
# Étape 6 : Télécharger les modèles
# ============================================
echo -e "${BLUE}[6/6] Téléchargement des modèles IA...${NC}"

# Modèle Ollama
echo -e "${YELLOW}📥 Téléchargement de Qwen3 30B (Ollama)...${NC}"
echo -e "${YELLOW}   (cela peut prendre 15-30 minutes selon ta connexion)${NC}"
ollama pull qwen3:30b

# Modèle Fish S2 Pro
echo -e "${YELLOW}📥 Téléchargement du modèle Fish S2 Pro...${NC}"
FISH_MODEL_DIR="${INSTALL_DIR}/models/fishaudio-s2-pro-8bit-mlx"
if [ ! -d "$FISH_MODEL_DIR" ] || [ -z "$(ls -A "$FISH_MODEL_DIR" 2>/dev/null)" ]; then
    echo -e "${YELLOW}   Téléchargement depuis Hugging Face...${NC}"
    echo -e "${YELLOW}   (cela peut prendre 5-10 minutes)${NC}"
    mkdir -p "$FISH_MODEL_DIR"
    
    # Installer huggingface-hub si nécessaire
    pip install -q huggingface-hub 2>/dev/null
    
    # Télécharger le modèle Fish Speech 1.5 MLX
    python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='fishaudio/fish-speech-1.5',
    local_dir='${FISH_MODEL_DIR}',
    local_dir_use_symlinks=False,
    ignore_patterns=['*.pt', '*.bin'],
)
" 2>&1 || echo -e "${YELLOW}   ⚠️  Téléchargement automatique échoué. Télécharge manuellement depuis :${NC}"
    
    if [ -d "$FISH_MODEL_DIR" ] && [ "$(ls -A "$FISH_MODEL_DIR" 2>/dev/null)" ]; then
        echo -e "${GREEN}  ✅ Modèle Fish S2 Pro téléchargé${NC}"
    else
        echo -e "${YELLOW}   https://huggingface.co/fishaudio/fish-speech-1.5${NC}"
        echo -e "${YELLOW}   Place les fichiers dans : ${FISH_MODEL_DIR}${NC}"
    fi
else
    echo -e "${GREEN}  ✅ Modèle Fish S2 Pro déjà présent${NC}"
fi

# Installer mlx-speech
echo -e "${YELLOW}📦 Installation de mlx-speech...${NC}"
pip install -q mlx-speech 2>/dev/null && echo -e "${GREEN}  ✅ mlx-speech installé${NC}" || echo -e "${YELLOW}  ⚠️  mlx-speech non installé (optionnel pour l'instant)${NC}"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Installation terminée !           ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "Pour lancer AudiobookForge :"
echo -e "  ${BLUE}cd ${INSTALL_DIR}${NC}"
echo -e "  ${BLUE}./start.sh${NC}"
echo ""
echo -e "Pour ouvrir dans Xcode :"
echo -e "  ${BLUE}open ${INSTALL_DIR}/Package.swift${NC}"
