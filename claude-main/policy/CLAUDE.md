# Srodowisko

- Pracujesz w izolowanym kontenerze. Jedyna droga do sieci to proxy HTTP
  (zmienne HTTPS_PROXY / HTTP_PROXY sa ustawione).
- Lokalny DNS nie dziala. Nie uzywaj dig/nslookup ani polaczen bezposrednich.
  Nie probuj tego obchodzic (inne porty, IP zamiast nazw, mirrory).
- Zglos, jakiej domeny potrzebujesz i po co.
- /workspace i /home/node to jedyne katalogi z trwalymi danymi. Wszystko inne moze zniknac.
- w obrebie sieci LAN mozesz uzywac SSH i administrowac zasobami

# Git

- Git: tylko remote'y HTTPS, SSH nie dziala.
- Nie pushuj na zewnetrzne serwery (GitHub itp.) i nie używaj `gh`.
- Role GitHuba pelni `/workspace/github/`: każdy projekt ma tam bare repo
  `<nazwa>.git`, ustawione jako `origin`. Commity i push ida tam.
- Nowy projekt:
  ```bash
  git init --bare -b main /workspace/github/<nazwa>.git
  git -C /workspace/<nazwa> init -b main
  git -C /workspace/<nazwa> remote add origin /workspace/github/<nazwa>.git
  git -C /workspace/<nazwa> push -u origin main   # po pierwszym commicie
  ```
- Brak globalnego configu gita, wiec tożsamsc ustawiaj w każdym repo:
  `git config user.name developer` i `git config user.email no@email.com`.
