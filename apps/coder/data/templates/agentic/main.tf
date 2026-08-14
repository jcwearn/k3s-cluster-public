terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

provider "coder" {
}

variable "use_kubeconfig" {
  type        = bool
  description = <<-EOF
  Use host kubeconfig? (true/false)

  Set this to false if the Coder host is itself running as a Pod on the same
  Kubernetes cluster as you are deploying workspaces to.

  Set this to true if the Coder host is running outside the Kubernetes cluster
  for workspaces.  A valid "~/.kube/config" must be present on the Coder host.
  EOF
  default     = false
}

variable "namespace" {
  type        = string
  description = "The Kubernetes namespace to create workspaces in (must exist prior to creating workspaces). If the Coder host is itself running as a Pod on the same Kubernetes cluster as you are deploying workspaces to, set this to the same namespace."
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU"
  description  = "The number of CPU cores"
  default      = "4"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 Cores"
    value = "2"
  }
  option {
    name  = "4 Cores"
    value = "4"
  }
  option {
    name  = "6 Cores"
    value = "6"
  }
  option {
    name  = "8 Cores"
    value = "8"
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory"
  description  = "The amount of memory in GB"
  default      = "8"
  icon         = "/icon/memory.svg"
  mutable      = true
  option {
    name  = "2 GB"
    value = "2"
  }
  option {
    name  = "4 GB"
    value = "4"
  }
  option {
    name  = "6 GB"
    value = "6"
  }
  option {
    name  = "8 GB"
    value = "8"
  }
}

data "coder_parameter" "home_disk_size" {
  name         = "home_disk_size"
  display_name = "Home disk size"
  description  = "The size of the home disk in GB"
  default      = "20"
  type         = "number"
  icon         = "/emojis/1f4be.png"
  mutable      = false
  validation {
    min = 1
    max = 99999
  }
}

data "coder_parameter" "git_repo" {
  name         = "git_repo"
  display_name = "Git Repository"
  description  = "The GitHub repository to clone (change and restart to switch repos)"
  type         = "string"
  default      = ""
  mutable      = true
  icon         = "/icon/git.svg"
  option {
    name  = "None"
    value = ""
  }
  option {
    name  = "agent-config"
    value = "https://github.com/jcwearn/agent-config"
  }
  option {
    name  = "ansible-runner"
    value = "https://github.com/jcwearn/ansible-runner"
  }
  option {
    name  = "anupamaandjackson"
    value = "https://github.com/jcwearn/anupamaandjackson"
  }
  option {
    name  = "cf-worker-email"
    value = "https://github.com/jcwearn/cf-worker-email"
  }
  option {
    name  = "dotfiles-coder"
    value = "https://github.com/jcwearn/dotfiles-coder"
  }
  option {
    name  = "homeassistant-config"
    value = "https://github.com/jcwearn/homeassistant-config"
  }
  option {
    name  = "jackson-wearn"
    value = "https://github.com/jcwearn/jackson-wearn"
  }
  option {
    name  = "k3s-cluster"
    value = "https://github.com/jcwearn/k3s-cluster"
  }
  option {
    name  = "priceatronic2"
    value = "https://github.com/jcwearn/priceatronic2"
  }
}

provider "kubernetes" {
  # Authenticate via ~/.kube/config or a Coder-specific ServiceAccount, depending on admin preferences
  config_path = var.use_kubeconfig == true ? "~/.kube/config" : null
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  repo_name      = data.coder_parameter.git_repo.value != "" ? basename(replace(data.coder_parameter.git_repo.value, ".git", "")) : ""
  is_k3s_cluster = data.coder_parameter.git_repo.value == "https://github.com/jcwearn/k3s-cluster"
}

# GitHub external auth for git operations
data "coder_external_auth" "github" {
  id = "github"
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = "amd64"
  dir  = local.repo_name != "" ? "/home/coder/${local.repo_name}" : "/home/coder"

  env = {
    SHELL = "/bin/zsh"
  }

  display_apps {
    vscode          = false
    vscode_insiders = false
    ssh_helper      = true
    web_terminal    = true
  }

  metadata {
    display_name = "CPU Usage"
    key          = "0_cpu_usage"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "RAM Usage"
    key          = "1_ram_usage"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Home Disk"
    key          = "3_home_disk"
    script       = "coder stat disk --path $${HOME}"
    interval     = 60
    timeout      = 1
  }

  metadata {
    display_name = "CPU Usage (Host)"
    key          = "4_cpu_usage_host"
    script       = "coder stat cpu --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Memory Usage (Host)"
    key          = "5_mem_usage_host"
    script       = "coder stat mem --host"
    interval     = 10
    timeout      = 1
  }

  metadata {
    display_name = "Load Average (Host)"
    key          = "6_load_host"
    # get load avg scaled by number of cores
    script   = <<EOT
      echo "`cat /proc/loadavg | awk '{ print $1 }'` `nproc`" | awk '{ printf "%0.2f", $1/$2 }'
    EOT
    interval = 60
    timeout  = 1
  }
}

# Dotfiles module
module "dotfiles" {
  source               = "registry.coder.com/coder/dotfiles/coder"
  version              = "1.4.2"
  agent_id             = coder_agent.main.id
  count                = data.coder_workspace.me.start_count
  default_dotfiles_uri = "https://github.com/jcwearn/dotfiles-coder"
}

module "cursor" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/cursor/coder"
  version  = "1.4.1"
  agent_id = coder_agent.main.id
  folder   = local.repo_name != "" ? "/home/coder/${local.repo_name}" : "/home/coder"
}

# Environment variable for GitHub token
resource "coder_env" "github_token" {
  agent_id = coder_agent.main.id
  name     = "GITHUB_TOKEN"
  value    = data.coder_external_auth.github.access_token
}

# Clone the project repository (handles repo switching)
resource "coder_script" "clone_repo" {
  agent_id           = coder_agent.main.id
  display_name       = "Clone Repository"
  run_on_start       = true
  start_blocks_login = true
  script             = <<-EOT
    #!/bin/bash
    REPO="${data.coder_parameter.git_repo.value}"
    if [ -n "$REPO" ]; then
      REPO_NAME=$(basename "$REPO" .git)
      if [ ! -d "/home/coder/$REPO_NAME/.git" ]; then
        echo "Cloning $REPO..."
        git clone "$REPO" "/home/coder/$REPO_NAME"
      else
        echo "Repository $REPO_NAME already exists, pulling latest..."
        cd "/home/coder/$REPO_NAME"
        git pull --ff-only || echo "Pull failed (diverged or dirty worktree), skipping update"
      fi
    fi
  EOT
}

# Configure git credentials
resource "coder_script" "git_config" {
  agent_id           = coder_agent.main.id
  display_name       = "Configure Git"
  run_on_start       = true
  start_blocks_login = false
  script             = <<-EOT
    #!/bin/bash
    # Write to local config file (not the symlinked .gitconfig)
    cat > ~/.gitconfig.local <<LOCALEOF
    [safe]
        directory = *
    [credential]
        helper = store
    LOCALEOF

    if [ -n "$GITHUB_TOKEN" ]; then
      echo "https://oauth2:$GITHUB_TOKEN@github.com" > ~/.git-credentials
      chmod 600 ~/.git-credentials
      echo "Git credentials configured"
    fi
  EOT
}

# Install k8s tools for k3s-cluster workspaces
resource "coder_script" "install_k8s_tools" {
  count              = local.is_k3s_cluster ? 1 : 0
  agent_id           = coder_agent.main.id
  display_name       = "Install K8s Tools"
  run_on_start       = true
  start_blocks_login = true
  script             = <<-EOT
    #!/bin/bash
    set -euo pipefail
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"

    # kubectl
    if [ ! -f "$INSTALL_DIR/kubectl" ]; then
      echo "Installing kubectl..."
      curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o "$INSTALL_DIR/kubectl"
      chmod +x "$INSTALL_DIR/kubectl"
    fi

    # flux
    if [ ! -f "$INSTALL_DIR/flux" ]; then
      echo "Installing flux..."
      curl -fsSL https://fluxcd.io/install.sh | FLUX_INSTALL_DIR="$INSTALL_DIR" bash
    fi

    # kustomize
    if [ ! -f "$INSTALL_DIR/kustomize" ]; then
      echo "Installing kustomize..."
      curl -fsSL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash -s -- 5.6.0 "$INSTALL_DIR"
    fi

    # helm
    if [ ! -f "$INSTALL_DIR/helm" ]; then
      echo "Installing helm..."
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="$INSTALL_DIR" USE_SUDO=false bash
    fi

    # sops
    if [ ! -f "$INSTALL_DIR/sops" ]; then
      echo "Installing sops..."
      curl -fsSL "https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64" -o "$INSTALL_DIR/sops"
      chmod +x "$INSTALL_DIR/sops"
    fi

    # age
    if [ ! -f "$INSTALL_DIR/age" ]; then
      echo "Installing age..."
      AGE_VERSION="v1.2.1"
      curl -fsSL "https://github.com/FiloSottile/age/releases/download/$AGE_VERSION/age-$AGE_VERSION-linux-amd64.tar.gz" | tar xz -C /tmp
      mv /tmp/age/age "$INSTALL_DIR/age"
      mv /tmp/age/age-keygen "$INSTALL_DIR/age-keygen"
      rm -rf /tmp/age
    fi

    echo "All k8s tools installed to $INSTALL_DIR"
  EOT
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${data.coder_workspace.me.id}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-pvc"
      "app.kubernetes.io/instance" = "coder-pvc-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      //Coder-specific labels.
      "com.coder.resource"       = "true"
      "com.coder.workspace.id"   = data.coder_workspace.me.id
      "com.coder.workspace.name" = data.coder_workspace.me.name
      "com.coder.user.id"        = data.coder_workspace_owner.me.id
      "com.coder.user.username"  = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk_size.value}Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "main" {
  count = data.coder_workspace.me.start_count
  depends_on = [
    kubernetes_persistent_volume_claim.home
  ]
  wait_for_rollout = false
  metadata {
    name      = "coder-${data.coder_workspace.me.id}"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"     = "coder-workspace"
      "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
      "app.kubernetes.io/part-of"  = "coder"
      "com.coder.resource"         = "true"
      "com.coder.workspace.id"     = data.coder_workspace.me.id
      "com.coder.workspace.name"   = data.coder_workspace.me.name
      "com.coder.user.id"          = data.coder_workspace_owner.me.id
      "com.coder.user.username"    = data.coder_workspace_owner.me.name
    }
    annotations = {
      "com.coder.user.email" = data.coder_workspace_owner.me.email
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "coder-workspace"
        "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
        "app.kubernetes.io/part-of"  = "coder"
        "com.coder.resource"         = "true"
        "com.coder.workspace.id"     = data.coder_workspace.me.id
        "com.coder.workspace.name"   = data.coder_workspace.me.name
        "com.coder.user.id"          = data.coder_workspace_owner.me.id
        "com.coder.user.username"    = data.coder_workspace_owner.me.name
      }
    }
    strategy {
      type = "Recreate"
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = "coder-workspace-${data.coder_workspace.me.id}"
          "app.kubernetes.io/part-of"  = "coder"
          "com.coder.resource"         = "true"
          "com.coder.workspace.id"     = data.coder_workspace.me.id
          "com.coder.workspace.name"   = data.coder_workspace.me.name
          "com.coder.user.id"          = data.coder_workspace_owner.me.id
          "com.coder.user.username"    = data.coder_workspace_owner.me.name
        }
      }
      spec {
        hostname = data.coder_workspace.me.name

        security_context {
          run_as_user     = 1000
          fs_group        = 1000
          run_as_non_root = true
        }

        container {
          name              = "dev"
          image             = "codercom/enterprise-base:ubuntu"
          image_pull_policy = "Always"
          command           = ["sh", "-c", coder_agent.main.init_script]
          security_context {
            run_as_user = "1000"
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          env {
            name  = "SHELL"
            value = "/bin/zsh"
          }
          resources {
            requests = {
              "cpu"    = "250m"
              "memory" = "512Mi"
            }
            limits = {
              "cpu"    = "${data.coder_parameter.cpu.value}"
              "memory" = "${data.coder_parameter.memory.value}Gi"
            }
          }
          volume_mount {
            mount_path = "/home/coder"
            name       = "home"
            read_only  = false
          }
          dynamic "volume_mount" {
            for_each = local.is_k3s_cluster ? [1] : []
            content {
              mount_path = "/home/coder/.kube/config"
              name       = "kubeconfig"
              sub_path   = "config"
              read_only  = true
            }
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.home.metadata.0.name
            read_only  = false
          }
        }
        dynamic "volume" {
          for_each = local.is_k3s_cluster ? [1] : []
          content {
            name = "kubeconfig"
            secret {
              secret_name = "coder-kubeconfig"
            }
          }
        }

        affinity {
          // This affinity attempts to spread out all workspace pods evenly across
          // nodes.
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 1
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_expressions {
                    key      = "app.kubernetes.io/name"
                    operator = "In"
                    values   = ["coder-workspace"]
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
