FROM codercom/code-server:latest

# Chạy với root để cài packages
USER root

# Cài Zsh
RUN apt-get update && \
    apt-get install -y zsh curl git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Chuyển về user coder
USER coder

# Cài Oh My Zsh (chạy với user coder để ~/.zshrc ở đúng chỗ)
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" --unattended && \
    echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.zshrc  # Optional: thêm path nếu cần

# Đặt Zsh làm default shell
RUN echo "/usr/bin/zsh" | sudo tee -a /etc/shells && \
    sudo chsh -s /usr/bin/zsh coder

# Quay lại entrypoint default
ENTRYPOINT ["/usr/bin/entrypoint.sh"]
CMD ["--bind-addr", "0.0.0.0:8080", "."]