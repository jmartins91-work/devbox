# syntax=docker/dockerfile:1
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG GCM_VERSION=2.6.1
ARG EXA_VERSION=0.10.1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ncurses-term \
      git \
      zsh \
      tmux \
      neovim \
      sudo \
      curl \
      ca-certificates \
      locales \
      ripgrep \
      fzf \
      cargo \
      bat \
      fd-find \
      git-delta \
      unzip \
      gpg \
      pass \
      less \
      openssh-client \
      xz-utils \
      tini \
      tzdata \
      procps \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

RUN userdel -r ubuntu 2>/dev/null || true && \
    groupdel ubuntu 2>/dev/null || true

RUN groupadd -g 1000 dev && \
    useradd -m -u 1000 -g 1000 -s /bin/zsh dev && \
    usermod -aG sudo dev && \
    echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev && \
    chmod 0440 /etc/sudoers.d/dev

RUN curl -fsSL \
      "https://github.com/git-ecosystem/git-credential-manager/releases/download/v${GCM_VERSION}/gcm-linux_amd64.${GCM_VERSION}.deb" \
      -o /tmp/gcm.deb && \
    dpkg -i /tmp/gcm.deb || (apt-get update && apt-get -f install -y && rm -rf /var/lib/apt/lists/*) && \
    rm -f /tmp/gcm.deb

RUN git config --system credential.helper /usr/local/bin/git-credential-manager && \
    git config --system credential.credentialStore gpg

RUN curl -fsSLO \
      "https://github.com/ogham/exa/releases/download/v${EXA_VERSION}/exa-linux-x86_64-v${EXA_VERSION}.zip" && \
    unzip -q "exa-linux-x86_64-v${EXA_VERSION}.zip" -d /tmp/exa && \
    mv /tmp/exa/bin/exa /usr/local/bin/exa && \
    rm -rf /tmp/exa "exa-linux-x86_64-v${EXA_VERSION}.zip"

RUN curl -fsSL https://starship.rs/install.sh | sh -s -- -y

RUN git clone --depth=1 https://github.com/zsh-users/zsh-completions.git /home/dev/.zsh-completions && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git /home/dev/.zsh-syntax-highlighting && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git /home/dev/.zsh-autosuggestions && \
    chown -R dev:dev /home/dev/.zsh-completions /home/dev/.zsh-syntax-highlighting /home/dev/.zsh-autosuggestions

USER dev
RUN curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash
USER root

RUN ln -sf /home/dev/.local/bin/zoxide /usr/local/bin/zoxide
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat && \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd

RUN FZF_VER="$(fzf --version | awk '{print $1}')" && \
    echo "Using fzf shell scripts for version: ${FZF_VER}" && \
    git clone --depth 1 --branch "${FZF_VER}" https://github.com/junegunn/fzf.git /tmp/fzf && \
    install -d /usr/local/share/fzf && \
    cp /tmp/fzf/shell/key-bindings.zsh /usr/local/share/fzf/key-bindings.zsh && \
    cp /tmp/fzf/shell/completion.zsh /usr/local/share/fzf/completion.zsh && \
    rm -rf /tmp/fzf

ENV PERSIST_DIR=/persist
RUN mkdir -p /persist/gnupg /persist/password-store /persist/state && \
    chown -R dev:dev /persist && \
    chmod 700 /persist/gnupg /persist/password-store

RUN cat << 'EOF' > /home/dev/.zshrc
export ZSH_DISABLE_COMPFIX=true
[[ -t 1 ]] && export GPG_TTY=$(tty)
export SHELL=/bin/zsh

export PASSWORD_STORE_DIR="${PASSWORD_STORE_DIR:-/persist/password-store}"
export GNUPGHOME="${GNUPGHOME:-/persist/gnupg}"

HISTFILE=~/.zsh_history
setopt HIST_IGNORE_DUPS
setopt HIST_VERIFY
setopt SHARE_HISTORY
setopt INC_APPEND_HISTORY

fpath=(/home/dev/.zsh-completions/src $fpath)

autoload -Uz compinit
rm -f ~/.zcompdump*
compinit -u

export FZF_TMUX=0
if [[ -o interactive ]]; then
  [[ -f /usr/local/share/fzf/key-bindings.zsh ]] && source /usr/local/share/fzf/key-bindings.zsh
  [[ -f /usr/local/share/fzf/completion.zsh ]] && source /usr/local/share/fzf/completion.zsh
  if (( $+widgets[fzf-history-widget] )); then
    bindkey '^R' fzf-history-widget
  fi
fi

if [[ -f /home/dev/.zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  source /home/dev/.zsh-autosuggestions/zsh-autosuggestions.zsh
fi

alias ll='ls -lh'
alias la='ls -lha'
alias l='ls -la'
alias e='exa --color=auto --group-directories-first'
alias el='exa -lh --color=auto --group-directories-first'
alias ea='exa -lha --color=auto --group-directories-first'

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

alias dfh='df -h'
alias dus='du -sh'
alias freeh='free -h'

alias rg='rg --color=auto --smart-case'
alias catn='bat --style=plain --paging=never'
alias catp='bat --paging=always'
alias fzf='command fzf --height 40% --layout=reverse --border'

alias v='nvim'
alias vim='nvim'

alias g='git'
alias gst='git status -sb'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gb='git branch'
alias gba='git branch -a'
alias gl='git log --oneline --decorate --graph --all'
alias gll='git log --stat'
alias gd='git diff'
alias gds='git diff --staged'
alias ga='git add'
alias gaa='git add -A'
alias gc='git commit'
alias gca='git commit --amend'
alias gcp='git cherry-pick'
alias gpl='git pull'
alias gps='git push'
alias gpr='git pull --rebase'
alias grh='git reset --hard'
alias gclean='git clean -fd'

command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"
eval "$(starship init zsh)"

if [[ -f /home/dev/.zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /home/dev/.zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi
EOF
RUN chown dev:dev /home/dev/.zshrc

RUN mkdir -p /home/dev/.config && \
    starship preset no-empty-icons -o /home/dev/.config/starship.toml && \
    chown -R dev:dev /home/dev/.config

ENV TZ=Etc/UTC
ENV PATH="/home/dev/.local/bin:${PATH}"

RUN mkdir -p /work && chown dev:dev /work

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

COPY validate_container.sh /usr/local/bin/validate-dev
RUN chmod +x /usr/local/bin/validate-dev

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD test -f /persist/state/devbox_ready || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
WORKDIR /work
CMD ["zsh"]