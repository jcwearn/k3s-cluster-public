# llama.cpp

[llama.cpp](https://github.com/ggml-org/llama.cpp) is a **self-hosted LLM inference server** with an OpenAI-compatible API. It runs CPU-only inference with ~27% better throughput than Ollama by eliminating abstraction overhead.

| Setting           | Value                                |
|-------------------|--------------------------------------|
| **Image**         | `ghcr.io/ggml-org/llama.cpp:server-b8637` |
| **Namespace**     | `llama-cpp`                          |
| **Access**        | In-cluster only (ClusterIP)          |
| **Port**          | `8080`                               |

---

## Models

Three separate Deployments serve one model each via the Qwen3 GGUF repos on Hugging Face:

| Deployment         | Model                   | Quantization | HF Repo                     |
|--------------------|-------------------------|--------------|------------------------------|
| `llama-cpp-1-7b`  | Qwen3-1.7B              | q8_0         | `Qwen/Qwen3-1.7B-GGUF`     |
| `llama-cpp-4b`    | Qwen3-4B                | q6_k         | `Qwen/Qwen3-4B-GGUF`       |
| `llama-cpp-8b`    | Qwen3-8B                | q4_k_m       | `Qwen/Qwen3-8B-GGUF`       |

All inference runs on CPU. GPU acceleration is disabled.

Models are downloaded from Hugging Face on first startup and cached to the shared PVC at `/models`.

---

## Storage

* **PVC**: `llama-cpp-models` — 20Gi, shared across all 3 Deployments
* **Access mode**: ReadWriteMany (RWX)
* **Storage class**: `truenas-nfs-rwx`

---

## Resources

| Deployment        | CPU request | CPU limit | Mem request | Mem limit |
|-------------------|-------------|-----------|-------------|-----------|
| `llama-cpp-1-7b` | 250m        | 2         | 2Gi         | 3Gi       |
| `llama-cpp-4b`   | 250m        | 2         | 4Gi         | 6Gi       |
| `llama-cpp-8b`   | 500m        | 4         | 5Gi         | 9Gi       |

---

## Integration

Each model is exposed to **Open WebUI** as an OpenAI-compatible endpoint:

* `http://llama-cpp-1-7b.llama-cpp.svc.cluster.local:8080/v1`
* `http://llama-cpp-4b.llama-cpp.svc.cluster.local:8080/v1`
* `http://llama-cpp-8b.llama-cpp.svc.cluster.local:8080/v1`

---

## Flux Object Path

All manifests live in `./infrastructure/llama-cpp/` and are reconciled via GitOps.
