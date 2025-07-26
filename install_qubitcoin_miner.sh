#!/usr/bin/env bash

####################################################################################
###
### QubitCoin CPU Miner Installation Script
###
####################################################################################

echo "Installing QubitCoin CPU Miner for HiveOS..."

# Функция установки зависимостей
install_dependencies() {
    echo "> Checking and installing dependencies..."
    
    # Проверяем, нужна ли установка зависимостей
    if ! ldconfig -p | grep -q libjansson || ! ldconfig -p | grep -q libstdc++; then
        echo "> Installing required dependencies..."
        
        # Обновляем список пакетов
        apt-get update >/dev/null 2>&1
        
        # Устанавливаем базовые зависимости
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            build-essential libtool autotools-dev automake pkg-config \
            bsdmainutils python3 libevent-dev libboost-dev libsqlite3-dev \
            libminiupnpc-dev libnatpmp-dev libzmq3-dev systemtap-sdt-dev \
            dirmngr gnupg gpg >/dev/null 2>&1
        
        # Проверяем версию Ubuntu
        UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "unknown")
        
        if [[ "$UBUNTU_VERSION" == "22.04" ]]; then
            echo "> Detected Ubuntu 22.04, updating GLIBC..."
            
            # Добавляем репозиторий Noble для обновления GLIBC
            echo "deb [signed-by=/usr/share/keyrings/ubuntu-noble.gpg] http://archive.ubuntu.com/ubuntu noble main universe" > /etc/apt/sources.list.d/noble-temp.list
            
            # Импортируем ключи
            gpg --keyserver keyserver.ubuntu.com --recv-keys 3B4FE6ACC0B21F32 >/dev/null 2>&1
            gpg --export 3B4FE6ACC0B21F32 > /usr/share/keyrings/ubuntu-noble.gpg 2>/dev/null
            gpg --keyserver keyserver.ubuntu.com --recv-keys 871920D1991BC93C >/dev/null 2>&1
            gpg --export 871920D1991BC93C >> /usr/share/keyrings/ubuntu-noble.gpg 2>/dev/null
            
            # Обновляем и устанавливаем новые версии библиотек
            apt-get update >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y -t noble libjansson4 libstdc++6 >/dev/null 2>&1
            
            # Убираем временный репозиторий
            rm -f /etc/apt/sources.list.d/noble-temp.list
            apt-get update >/dev/null 2>&1
            
            echo "> GLIBC updated successfully"
        fi
        
        echo "> Dependencies installed successfully"
    else
        echo "> Dependencies already installed"
    fi
}

# Устанавливаем зависимости
install_dependencies
