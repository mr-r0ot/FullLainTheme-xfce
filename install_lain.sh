chmod +x Set_IconTheme.sh
sudo ./Set_IconTheme.sh


# set fontsystem JetBrains
sudo /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JetBrains/JetBrainsMono/master/install_manual.sh)"


# Install WhiteSur GTK Theme
git clone https://github.com/vinceliuice/WhiteSur-gtk-theme.git --depth=1
cd WhiteSur-gtk-theme
chmod +x install.sh
sudo ./install.sh --name LainTheme -c dark --alt normal -t purple --scheme nord -o normal --roundedmaxwindow --silent-mode -l
cd ..




#  --monterey اهر را از Big Sur به سمت macOS Monterey می‌برد.





chmod +x Set_Dock.sh
sudo ./Set_Dock.sh

