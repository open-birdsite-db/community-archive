# Roadmap

## Archive Infrastructure

- [x] S3 storage for archives, and API to serve it
- [x] Archive filtering and privacy settings
- [x] Postgres DB for pooled archives, and API to serve it
- [x] Row-level security
- [ ] Small fixes:
  - [ ] Split archive.json into files and chunks for convenient storage
  - [ ] Download and store avatars
  - [ ] Move from multiple archive_uploads to a single one
- [ ] Implement tests for uploading and privacy
- [ ] Embeddings infrastructure:
  - [ ] Create and store embeddings
    - [ ] using people's openai api key or letting them pay us to do it
  - [ ] Develop economics model for user charging
- [ ] Browser extension for DB updates via Twitter client API scraping

## Apps Using the Data

- [x] Website
  - [x] Twitter-like advanced full text search
  - [x] User pages with top tweets and a button to copy as text (to put in LLM context)
- [x] [Keyword and concept trends analysis ](https://labs-community-archive.streamlit.app/)
- [ ] Website improvements:
  - [ ] Restyle front page
  - [ ] Render threads
- [ ] User clones via tweet distillation and LLM simulation
- [ ] Semantic search
- [ ] User summary pages (interests, projects, relationships)
- [ ] Discourse mapping
- [ ] Discussion reranking with bridging algorithms
- [ ] WebSim with DB access for on-the-fly data analysis and UI
- [ ] Interactions network visualization and temporal analysis
