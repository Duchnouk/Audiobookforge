"""
API FastAPI pour AudiobookForge.
Sert d'interface entre l'app SwiftUI et les services Dockerisés.
"""

import json
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="AudiobookForge Backend API")

# Dossier de travail
DATA_DIR = Path(os.environ.get("DATA_DIR", "/app/data"))
MODEL_DIR = Path(os.environ.get("MODEL_DIR", "/app/models/fishaudio-s2-pro-8bit-mlx"))
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://ollama:11434")

DATA_DIR.mkdir(parents=True, exist_ok=True)


# ============================================
# Modèles de données
# ============================================

class ExtractRequest(BaseModel):
    file_path: str
    file_type: str  # epub, pdf, docx


class ExtractResponse(BaseModel):
    chapters: list[dict]
    metadata: dict
    cover_path: Optional[str] = None


class TagRequest(BaseModel):
    chapter_text: str


class TagResponse(BaseModel):
    tagged_text: str


class GenerateRequest(BaseModel):
    text: str
    reference_audio: str
    reference_text: str
    output_path: str
    speed: float = 1.0
    temperature: float = 0.8


class GenerateResponse(BaseModel):
    output_path: str
    duration: float


# ============================================
# Endpoints
# ============================================

@app.get("/health")
async def health():
    """Vérifie que l'API et les dépendances sont accessibles."""
    # Vérifier Ollama
    try:
        import httpx
        r = httpx.get(f"{OLLAMA_HOST}/api/tags", timeout=5)
        ollama_ok = r.status_code == 200
    except Exception:
        ollama_ok = False

    return {
        "status": "ok",
        "ollama": ollama_ok,
        "model_dir": MODEL_DIR.exists(),
    }


@app.post("/extract", response_model=ExtractResponse)
async def extract_text(req: ExtractRequest):
    """Extrait le texte d'un fichier EPUB/PDF/DOCX."""
    script_map = {
        "epub": "extract_epub.py",
        "pdf": "extract_pdf.py",
        "docx": "extract_docx.py",
    }

    script = script_map.get(req.file_type)
    if not script:
        raise HTTPException(400, f"Type non supporté : {req.file_type}")

    script_path = Path("/app/backend/scripts") / script
    if not script_path.exists():
        raise HTTPException(500, f"Script introuvable : {script_path}")

    output_dir = tempfile.mkdtemp(dir=str(DATA_DIR))

    try:
        result = subprocess.run(
            ["python3", str(script_path), "--input", req.file_path, "--output", output_dir],
            capture_output=True, text=True, timeout=120,
        )

        if result.returncode != 0:
            raise HTTPException(500, f"Erreur d'extraction : {result.stderr}")

        # Lire les résultats
        chapters_file = Path(output_dir) / "chapters.json"
        metadata_file = Path(output_dir) / "metadata.json"
        cover_file = Path(output_dir) / "cover.jpg"

        chapters = json.loads(chapters_file.read_text()) if chapters_file.exists() else []
        metadata = json.loads(metadata_file.read_text()) if metadata_file.exists() else {"title": "", "author": ""}
        cover_path = str(cover_file) if cover_file.exists() else None

        return ExtractResponse(chapters=chapters, metadata=metadata, cover_path=cover_path)

    except subprocess.TimeoutExpired:
        raise HTTPException(500, "Timeout lors de l'extraction")
    finally:
        # Nettoyer
        import shutil
        shutil.rmtree(output_dir, ignore_errors=True)


@app.post("/tags", response_model=TagResponse)
async def inject_tags(req: TagRequest):
    """Injecte des balises émotionnelles via Ollama."""
    import httpx

    prompt = f"""Tu es un directeur artistique spécialisé dans la narration d'audiobooks.
Tu reçois un passage de texte en français.
Ta tâche est d'insérer des balises d'expression Fish Audio S2 Pro directement dans le texte,
aux endroits précis où elles améliorent la narration.

Règles strictes :
- Ne modifie JAMAIS le texte original, les mots, la ponctuation ou l'orthographe
- Insère uniquement des balises entre crochets : [whisper], [excited], [sad], [pause],
  [angry], [laughing], [chuckle], [emphasis], [clearing throat], [inhale],
  [professional broadcast tone], [warm], [tense], [mysterious]
- Une balise s'applique à la phrase ou segment qui la suit immédiatement
- N'abuse pas des balises : maximum 1 balise tous les 3-4 phrases en moyenne
- Pour les dialogues : utilise [excited], [whisper], [angry] etc. selon le contexte émotionnel
- Pour la narration neutre : laisse sans balise ou utilise [warm] occasionnellement
- Retourne uniquement le texte enrichi, sans commentaires ni explications

Texte à enrichir :
{req.chapter_text}"""

    try:
        async with httpx.AsyncClient(timeout=300) as client:
            r = await client.post(
                f"{OLLAMA_HOST}/api/generate",
                json={
                    "model": "qwen3:30b",
                    "prompt": prompt,
                    "temperature": 0.3,
                    "top_p": 0.9,
                    "stream": False,
                },
            )
            r.raise_for_status()
            data = r.json()
            return TagResponse(tagged_text=data.get("response", ""))

    except httpx.RequestError as e:
        raise HTTPException(503, f"Ollama inaccessible : {e}")


@app.post("/generate", response_model=GenerateResponse)
async def generate_audio(req: GenerateRequest):
    """Génère un fichier audio via Fish S2 Pro."""
    script_path = Path("/app/backend/scripts/generate/fish_s2_pro.py")
    if not script_path.exists():
        raise HTTPException(500, f"Script introuvable : {script_path}")

    os.makedirs(os.path.dirname(req.output_path), exist_ok=True)

    try:
        result = subprocess.run(
            [
                "python3", str(script_path),
                "--text", req.text,
                "--model-dir", str(MODEL_DIR),
                "--reference-audio", req.reference_audio,
                "--reference-text", req.reference_text,
                "--output", req.output_path,
                "--length-scale", str(req.speed),
                "--temperature", str(req.temperature),
            ],
            capture_output=True, text=True, timeout=300,
        )

        if result.returncode != 0:
            raise HTTPException(500, f"Erreur de génération : {result.stderr}")

        # Obtenir la durée via ffprobe
        duration = 0.0
        try:
            probe = subprocess.run(
                ["ffprobe", "-v", "quiet", "-print_format", "json", "-show_format", req.output_path],
                capture_output=True, text=True, timeout=10,
            )
            probe_data = json.loads(probe.stdout)
            duration = float(probe_data.get("format", {}).get("duration", 0))
        except Exception:
            pass

        return GenerateResponse(output_path=req.output_path, duration=duration)

    except subprocess.TimeoutExpired:
        raise HTTPException(500, "Timeout lors de la génération audio")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
