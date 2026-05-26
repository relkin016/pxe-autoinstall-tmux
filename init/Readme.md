## Необхідні засоби:
1. Пристрій Android на базі arm процесора android 7.0, вільними 2ГБ внутрішньої пам'яті
2. Попередньо базово налаштований MikroTik (DHCP сервер та DHCP-pool, LAN мережа) на RouterOS 7ої версії з логіном та паролем та параметром "/ip service set api disabled=no"
3. Пристрій з Debian/Ubuntu/LMDE (для роботи з Ansible)
4. Пристрій, на якому буде розгорнуто ОС

## Порядок проведення попередніх налаштувань:
1. [Налаштувати відладку](https://they.liberty.cx.ua/psikhologiya/yak-aktivuvati-adb-na-android-prostiy-gid-dlya-pochatkivciv.html) на Android пристрої
2. Приєднати усі хости в одну мережу
3. Приєднати Android пристрій до хосту з Ansible по USB або налашутвати відладку по WIFI (див. adb.md)
4. Покласти APK файли Termux у директорію $HOME/apks/ (опціонально)
5. Запустити скрипт: bash install.sh

### Підготовка розгортання
Перед розгортанням переконайтеся, що усі умови вище задоволені, та виконайте команди
```bash
# На пристрої з Debian/Ubuntu/LMDE (для роботи з Ansible)
sudo apt-get update && sudo apt-get install git ansible -y
git clone https://github.com/relkin016/phone_as_infracontroller.git
cd phone_as_infracontroller/init
bash install.sh
```

### Базове налаштування Termux
#### Для базового налаштування Termux необхідно ввести наступні команди у оболонці Termux:
```bash
# На телефоні з Termux

# 1. Оновити пакети
# У разі створення діалогових вікон натискаємо "Y"
pkg update && yes | pkg upgrade -y

# 2. Інсталювати залежності для роботи з Ansible
pkg install openssh python

# 3. Налаштувати пароль користувача (для роботи по SSH)
passwd

# 4. Запуск sshd
sshd

# 5. Дізнатися ім'я користувача
whoami          # Це ваше ім'я
```

### Налаштування МКВ після первинної ініціалізації 
#### Після проведення встановлення та налаштування Termux необхідно повністю налаштувати МКВ до роботи
1. Запустіть скрипт додавання користувача:
```bash
bash "$HOME/post-install.sh"
```
та підтвердіть автозапуск другого етапу.
**Після проходження 2-го етапу ЕОМ буде налаштована у ролі МКВ**

[//]: # (TODO rebase ansible playbooks to role)

#### Для тестування ролі МКВ можна використати готовий пайплайн з директорії pipelines



[//]: # (TODO: busybox + pxe + iso)