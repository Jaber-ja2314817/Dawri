---
tags: [ai, models]
---

# Model Choices (Hugging Face Hub)

> Check each model page on the Hub at kickoff: license, gating, and whether it's available on HF Inference Providers or needs your own endpoint. Ask the HF mentors at the venue about inference credits / GPU access early.

| Job | First choice | Why | Fallback |
|---|---|---|---|
| Dialogue, intake JSON, Arabic | **QCRI/Fanar-2-27B-Instruct** | Qatar's own Arabic-first model (QCRI/HBKU), Apache-2.0, 32k context, built on Gemma 3 27B. Huge "made in Qatar" story | **QCRI/Fanar-1-9B-Instruct** (faster, smaller) or any small instruct model that handles Arabic |
| Speech → text (AR + EN) | **openai/whisper-large-v3-turbo** | Fast, multilingual, runs on modest GPU | whisper-small for CPU; or typing |
| Doctor handoff summary (EN) | **google/medgemma-27b-text-it** (gated: accept terms on the Hub) | Medical-domain tuned | Same Fanar model with the handoff prompt |
| Red flags | **Rules** (AR/EN keyword list) + LLM double-check | Deterministic, explainable | Rules only |
| Optional TTS | facebook/mms-tts-ara (Arabic) | Voice replies for elderly users | Text only |

## Compute reality check
- A 27B model in bf16 needs ~55 GB of GPU memory → one 80 GB GPU, or 4-bit quantisation (~16 GB), or a hosted endpoint.
- For the hackathon: call it through **Inference Providers / an Inference Endpoint**, or a **ZeroGPU Space**. Don't try to load 27B on a laptop.
- Keep one `llm.py` adapter with `MODEL_ID` in env vars so swapping is a one-line change.

```python
# backend/ai/llm.py
import os
from huggingface_hub import InferenceClient

client = InferenceClient(model=os.environ["LLM_MODEL_ID"], token=os.environ["HF_TOKEN"])

def chat(messages, max_tokens=400, temperature=0.2):
    out = client.chat_completion(messages=messages, max_tokens=max_tokens,
                                 temperature=temperature)
    return out.choices[0].message.content
```

```python
# backend/ai/asr.py
import os
from huggingface_hub import InferenceClient
asr = InferenceClient(model=os.environ.get("ASR_MODEL_ID", "openai/whisper-large-v3-turbo"),
                      token=os.environ["HF_TOKEN"])

def transcribe(audio_bytes: bytes) -> str:
    return asr.automatic_speech_recognition(audio_bytes).text
```

## Latency budget (for a smooth demo)
| Step | Target |
|---|---|
| ASR per utterance | < 2 s |
| LLM question turn | < 3 s (stream tokens) |
| Intake JSON | < 5 s |
| Handoff summary | < 6 s |

If Fanar-27B misses these at the venue → switch the chat to the 9B model and keep 27B (or MedGemma) only for the one-off handoff summary.

## Pitch line
"Our receptionist speaks Gulf Arabic because it's built on **Fanar**, Qatar's own open model — published on Hugging Face."
