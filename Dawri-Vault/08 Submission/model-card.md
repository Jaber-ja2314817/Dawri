---
license: apache-2.0
base_model: QCRI/Fanar-1-9B-Instruct
library_name: peft
language:
- ar
- en
tags:
- qai-hf-hackathon-2026
- lora
- arabic
- healthcare-intake
- qatar
---

<!-- VERIFY BEFORE UPLOAD: the license line must match the base model card (QCRI/Fanar-1-9B-Instruct). -->

# Dawri intake LoRA (Fanar 1 9B)

A LoRA adapter on `QCRI/Fanar-1-9B-Instruct`, trained during the Qai x Hugging Face Hackathon (Doha, 5 to 7 November 2026) for Dawri, an AI front desk for Qatar's primary health centres. Synthetic data only. Not for clinical use.

## What it does

It teaches the model Dawri's receptionist format: ask one short, plain question at a time, in Arabic or English, and produce a structured intake. It never diagnoses or prescribes.

## Training

- Method: LoRA, 1.5 epochs, on an A10G large GPU through Hugging Face Jobs (77.6 GPU minutes).
- Data: synthetic Arabic and English conversations generated from Dawri's scripted receptionist. No real patients, no real health data.

## Results (our own test, small samples)

| Measure | Fanar base | This adapter |
| --- | --- | --- |
| Questions passing Dawri's reply check, English | 1 of 50 | 50 of 50 |
| Questions passing Dawri's reply check, Arabic | 0 of 50 | 50 of 50 |
| Valid intake, English | 4 of 27 | 25 of 27 |
| Valid intake, Arabic | 2 of 36 | 31 of 36 |
| Asked the right next topic | 0 of 100 | 89 of 100 |
| **Recognised an emergency** | **9 of 13** | **0 of 13** |

The figures come from the training run's own report and were not independently rechecked.

## Limitations

- **It lost emergency recognition.** The training data contained no emergencies, so the adapter recognised none of the 13 emergency test cases. Do not use it for triage or safety screening.
- It mostly imitates the script: only 14 different questions appeared in the 100 tested.
- About 5 of 56 accepted intakes had a clearly wrong complaint, by an unreviewed manual reading.
- Intake took 13 to 17 seconds, over the live app's 10-second limit, and no inference provider serves it.

## How Dawri uses it

It is published as a results-only demo. The live Dawri Space does not use it for chat, because of the emergency result above. The Space runs Gemma 4 26B and Whisper large-v3-turbo through Hugging Face Inference Providers, with deterministic emergency rules running before any model.

Space: https://huggingface.co/spaces/qai-hf-hackathon-2026/team-232-dawri-app
