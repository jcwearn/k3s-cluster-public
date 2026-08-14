# Open WebUI

[Open WebUI](https://github.com/open-webui/open-webui) is a **self-hosted web interface for large language models** that provides an OpenAI-compatible chat experience. It serves as the primary user-facing interface for interacting with AI models in the cluster.

| Setting            | Value                              |
|--------------------|------------------------------------|
| **URL**            | `https://chat.${DOMAIN}`           |
| **Chart**          | `open-webui` v10.2.1               |
| **Image**          | `ghcr.io/open-webui/open-webui`    |
| **Storage**        | PVC `open-webui-data` (5Gi, RWX)   |
| **Ingress**        | Envoy Gateway HTTPRoute            |
| **Namespace**      | `open-webui`                        |

## Architecture

Open WebUI is configured to use external AI APIs:

* **Backend APIs** - OpenAI API and Google Gemini API as OpenAI-compatible endpoints
* **llama.cpp** - Connected to 3 local llama.cpp instances (Qwen3 1.7B, 4B, 8B) via OpenAI-compatible API
* **Default Model** - `Qwen3-8B-Q4_K_M` (local llama.cpp model)
* **Pipelines** - Disabled

## Features

* **Web-based chat interface** - Clean, intuitive UI for LLM interactions
* **OpenAI API compatibility** - Works with any OpenAI-compatible backend
* **Multi-model support** - Switch between different AI models
* **Conversation history** - Persistent chat sessions stored locally
* **User management** - Multi-user support with authentication
* **Markdown rendering** - Rich text formatting in responses

## Access

Open WebUI is accessible through multiple methods:

* **Public URL**: `https://chat.${DOMAIN}` (via Envoy Gateway with TLS)
* **Tailscale**: `chat` hostname on the Tailnet
* **LoadBalancer IP**: `${LAN_PREFIX}.27` (via kube-vip)

## Storage

The application uses a persistent volume claim (`open-webui-data`) with the following specifications:

* **Size**: 5Gi
* **Access mode**: ReadWriteMany (RWX)
* **Storage class**: TrueNAS NFS
* **Purpose**: Stores user data, chat history, and application settings

## Resources

* **CPU**: 250m (request) to 1 core (limit)
* **Memory**: 512Mi (request) to 1Gi (limit)

---

> **TODO** – Document user authentication setup, backup procedures for chat history, and integration with additional model providers.
