# Move to the org and upload (team 232)

Targets
- Model: qai-hf-hackathon-2026/team-232-dawri
- Space: qai-hf-hackathon-2026/team-232-dawri-app

Run from the repo root, after `hf auth login` (do not paste the token anywhere else).
If you get a 403, your token lacks org write access: use the web steps below instead.

```python
from huggingface_hub import HfApi
api = HfApi()
ORG = "qai-hf-hackathon-2026"

# 1. Model: move the adapter into the org, make it public, upload the card
api.move_repo(from_id="xTamim/dawri-fanar-9b-lora", to_id=f"{ORG}/team-232-dawri", repo_type="model")
api.update_repo_settings(f"{ORG}/team-232-dawri", repo_type="model", private=False)
api.upload_file(path_or_fileobj="Dawri-Vault/08 Submission/model-card.md", path_in_repo="README.md",
                repo_id=f"{ORG}/team-232-dawri", repo_type="model", commit_message="Add model card")

# 2. Space: move into the org, then upload the updated card (README.md already edited locally)
api.move_repo(from_id="xTamim/dawri", to_id=f"{ORG}/team-232-dawri-app", repo_type="space")
api.upload_file(path_or_fileobj="README.md", path_in_repo="README.md",
                repo_id=f"{ORG}/team-232-dawri-app", repo_type="space", commit_message="Add hackathon tag and model link")
```

Web fallback: each repo > Settings > "Rename or transfer" > owner `qai-hf-hackathon-2026`, name as above.
Model: Settings > make public, then Edit model card and paste `model-card.md`.

After the Space move, check (the order matters, do it before recording the video)
1. Space Settings still has the secrets HF_TOKEN and DEMO_PASSCODE (re-add if missing).
2. Hardware is still cpu-upgrade and the Space shows Running.
3. https://<org>-team-232-dawri-app.hf.space/api/health says ai_mode is real.
4. The Space card shows the tag qai-hf-hackathon-2026 and links the model.
5. The model page shows the tag, a model card, and is public (open it in a private window).
6. Then commit README.md in git. Keep the old xTamim Space running until all checks pass.
