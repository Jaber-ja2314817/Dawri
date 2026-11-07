# Submission sheet row (only the video link is still to fill in)

| Column | Value |
| --- | --- |
| Project title | Dawri (دوري): an AI front desk for walk-ins at Qatar's health centres |
| Problem | Most visits to Qatar's primary health centres are walk-ins that start at a front desk where staff record why you came, before triage, doctor and pharmacy. Existing apps cover appointments and records, and we found no digital path for walk-ins. |
| Space URL | https://huggingface.co/spaces/qai-hf-hackathon-2026/team-232-dawri-app |
| Fine-tuned model URL | https://huggingface.co/qai-hf-hackathon-2026/team-232-dawri |
| Base model | QCRI/Fanar-1-9B-Instruct |
| How the model is used | LoRA fine-tune on synthetic Arabic and English intake conversations to learn Dawri's one-short-question format. In our test it passed Dawri's reply check 100 of 100 times (base: 1 of 100) but recognised 0 of 13 emergencies (base: 9 of 13), so the live Space does not use it for chat. The Space runs Gemma 4 26B and Whisper large-v3-turbo through Inference Providers, with emergency rules running first. The adapter is published as a results-only demo. |
| Demo video URL | (link set to "anyone with the link can view") |
| Dataset URL (optional) | leave blank unless the dataset is made public under the org |
| Submitted | Yes (set last, before 14:00) |
