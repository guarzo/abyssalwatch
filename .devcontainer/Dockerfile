FROM elixir:1.19-otp-27

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    git \
    inotify-tools \
    libpq-dev \
    netcat-openbsd \
    postgresql-client \
    sudo \
    wget \
    zsh \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (for Phoenix assets)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Switch to non-root user
USER $USERNAME

# Set up Elixir environment
RUN mix local.hex --force && mix local.rebar --force

# Install Phoenix generator
RUN mix archive.install hex phx_new --force

# Create directories for caches
RUN mkdir -p /home/$USERNAME/.hex /home/$USERNAME/.mix

# Set working directory
WORKDIR /workspace

# Default shell
SHELL ["/bin/zsh", "-c"]
