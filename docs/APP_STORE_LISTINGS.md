# App Store Listings — QuickProtect

Localized App Store metadata for every language the app ships in.
Copy each field into **App Store Connect → your app → (localization) → App Store** tab.

App Store Connect field limits (per localization):

| Field | Limit |
|---|---|
| App Name | 30 characters |
| Subtitle | 30 characters |
| Promotional Text | 170 characters (editable anytime, no review) |
| Keywords | 100 characters, comma-separated (no spaces needed after commas) |
| Description | 4000 characters |
| What's New (release notes) | 4000 characters |

Notes:
- **App Name** is kept as `QuickProtect` in every locale (brand name, well under 30 chars).
- Keywords use technical tokens plus the *product* names used nominatively (UniFi, Protect). The **company** name (Ubiquiti) was removed from keywords for Guideline 5.2.1 — a company trademark as a keyword is the clearest trigger.
- Each description ends with a **non-affiliation disclaimer** — required when third-party trademarks (UniFi / Ubiquiti) appear in metadata; keep it.
- **Subtitles are brand-free** (Guideline 5.2.1): the subtitle is name-adjacent, so it must not carry the trademark. The trademark appears only nominatively in the description body + REQUIREMENTS.
- **Operational source of truth is `fastlane/metadata/`** (what `fastlane deliver` uploads). This file mirrors it for reference.
- Re-check Subtitle/Keyword character counts in App Store Connect after any edit; some languages run long.

---

## 🇬🇧 English (en) — primary

**App Name**
```
QuickProtect
```

**Subtitle**
```
Live cameras in your menu bar
```

**Promotional Text**
```
Your UniFi Protect cameras, one click from the menu bar. Live feeds, PTZ control, fullscreen — all local, all private. No cloud, no account, no tracking.
```

**Keywords**
```
UniFi,Protect,camera,security,surveillance,CCTV,NVR,RTSP,PTZ,menu bar,live,IP camera
```

**Description**
```
QuickProtect puts your UniFi Protect cameras one click away — right in your Mac's menu bar.

Click the menu-bar icon to see every camera in a live grid. Click a camera to focus it, and press F for fullscreen. For PTZ cameras, pan and tilt with the arrow keys or the on-screen pad.

QuickProtect talks directly to your controller on your local network over RTSP/RTSPS. No cloud, no account, no tracking — your video never leaves your network.

FEATURES
• Live camera grid in your menu bar
• One-click focus and fullscreen
• PTZ control with the keyboard or an on-screen pad
• Zoom and pan within a feed
• Resizable window, drag to reorder cameras
• Per-camera size and hide options
• Light, dark, and automatic themes with accent colors
• Global keyboard shortcut to show or hide the grid
• Launch at login
• Free and open-source (MIT)

REQUIREMENTS
• A UniFi Protect controller on your local network
• An Integration API key from your controller (for the camera list and live streams)
• A local admin account — optional, only needed for PTZ control

QuickProtect is an independent app and is not affiliated with or endorsed by Ubiquiti Inc. UniFi and UniFi Protect are trademarks of Ubiquiti Inc.
```

**What's New**
```
• Fixed a crash in the stream overview when several camera streams changed at once.
• The camera panel now closes when you switch to another app with Command-Tab or the Dock.
• Update checks no longer announce a release until its Mac build is available.
```

---

## 🇩🇪 German (de)

**App Name**
```
QuickProtect
```

**Subtitle**
```
Kameras in der Menüleiste
```

**Promotional Text**
```
Deine UniFi-Protect-Kameras, nur einen Klick entfernt. Live-Feeds, PTZ-Steuerung, Vollbild – alles lokal und privat. Keine Cloud, kein Konto, kein Tracking.
```

**Keywords**
```
UniFi,Protect,Kamera,Sicherheit,Überwachung,CCTV,NVR,RTSP,PTZ,Menüleiste,live,IP-Kamera
```

**Description**
```
QuickProtect bringt deine UniFi-Protect-Kameras mit nur einem Klick direkt in die Menüleiste deines Macs.

Klicke auf das Menüleistensymbol, um alle Kameras in einem Live-Raster zu sehen. Klicke auf eine Kamera, um sie zu vergrößern, und drücke F für Vollbild. PTZ-Kameras schwenkst und neigst du mit den Pfeiltasten oder dem Steuerkreuz auf dem Bildschirm.

QuickProtect kommuniziert direkt mit deinem Controller im lokalen Netzwerk über RTSP/RTSPS. Keine Cloud, kein Konto, kein Tracking – dein Video verlässt nie dein Netzwerk.

FUNKTIONEN
• Live-Kameraraster in der Menüleiste
• Großansicht und Vollbild mit einem Klick
• PTZ-Steuerung per Tastatur oder Steuerkreuz
• Zoomen und Schwenken im Bild
• Größenveränderbares Fenster, Kameras per Ziehen neu anordnen
• Größe und Sichtbarkeit pro Kamera einstellbar
• Helles, dunkles und automatisches Design mit Akzentfarben
• Globaler Kurzbefehl zum Ein- und Ausblenden des Rasters
• Beim Anmelden starten
• Kostenlos und quelloffen (MIT)

VORAUSSETZUNGEN
• Ein UniFi-Protect-Controller im lokalen Netzwerk
• Ein Integrations-API-Schlüssel deines Controllers (für die Kameraliste und Live-Streams)
• Ein lokales Admin-Konto – optional, nur für die PTZ-Steuerung nötig

QuickProtect ist eine unabhängige App und steht in keiner Verbindung zu Ubiquiti Inc. und wird von Ubiquiti Inc. nicht unterstützt. UniFi und UniFi Protect sind Marken von Ubiquiti Inc.
```

**What's New**
```
• Absturz in der Stream-Übersicht behoben, wenn sich mehrere Kamera-Streams gleichzeitig geändert haben.
• Das Kamerafenster schließt sich jetzt, wenn du mit Befehl-Tab oder über das Dock zu einer anderen App wechselst.
• Update-Prüfungen melden eine neue Version erst, wenn deren Mac-Build verfügbar ist.
```

---

## 🇫🇷 French (fr) — formal "vous"

**App Name**
```
QuickProtect
```

**Subtitle**
```
Caméras dans la barre de menus
```

**Promotional Text**
```
Vos caméras UniFi Protect, à un clic de la barre des menus. Flux en direct, contrôle PTZ, plein écran — tout en local et privé. Pas de cloud, pas de compte, pas de suivi.
```

**Keywords**
```
UniFi,Protect,caméra,sécurité,surveillance,CCTV,NVR,RTSP,PTZ,barre des menus,caméra IP
```

**Description**
```
QuickProtect place vos caméras UniFi Protect à un clic — directement dans la barre des menus de votre Mac.

Cliquez sur l'icône de la barre des menus pour voir toutes vos caméras dans une grille en direct. Cliquez sur une caméra pour l'agrandir et appuyez sur F pour le plein écran. Pour les caméras PTZ, effectuez un panoramique et inclinez avec les touches fléchées ou le pavé à l'écran.

QuickProtect communique directement avec votre contrôleur sur votre réseau local via RTSP/RTSPS. Pas de cloud, pas de compte, pas de suivi — votre vidéo ne quitte jamais votre réseau.

FONCTIONNALITÉS
• Grille de caméras en direct dans la barre des menus
• Agrandissement et plein écran en un clic
• Contrôle PTZ au clavier ou avec un pavé à l'écran
• Zoom et panoramique dans un flux
• Fenêtre redimensionnable, réorganisation des caméras par glissement
• Taille et masquage réglables par caméra
• Thèmes clair, sombre et automatique avec couleurs d'accent
• Raccourci clavier global pour afficher ou masquer la grille
• Lancement à la connexion
• Gratuit et open source (MIT)

CONFIGURATION REQUISE
• Un contrôleur UniFi Protect sur votre réseau local
• Une clé de l'API d'intégration de votre contrôleur (pour la liste des caméras et les flux en direct)
• Un compte administrateur local — facultatif, requis uniquement pour le contrôle PTZ

QuickProtect est une app indépendante, non affiliée à Ubiquiti Inc. ni approuvée par Ubiquiti Inc. UniFi et UniFi Protect sont des marques d'Ubiquiti Inc.
```

**What's New**
```
• Correction d'un plantage de la vue d'ensemble des flux lorsque plusieurs flux de caméra changeaient en même temps.
• La fenêtre des caméras se ferme désormais lorsque vous passez à une autre app avec Commande-Tab ou le Dock.
• Les vérifications de mise à jour n'annoncent plus une version tant que sa version Mac n'est pas disponible.
```

---

## 🇪🇸 Spanish (es) — informal "tú"

**App Name**
```
QuickProtect
```

**Subtitle**
```
Cámaras en la barra de menús
```

**Promotional Text**
```
Tus cámaras UniFi Protect, a un clic de la barra de menús. Transmisiones en vivo, control PTZ, pantalla completa: todo local y privado. Sin nube, sin cuenta, sin rastreo.
```

**Keywords**
```
UniFi,Protect,cámara,seguridad,vigilancia,CCTV,NVR,RTSP,PTZ,barra de menús,cámara IP
```

**Description**
```
QuickProtect pone tus cámaras UniFi Protect a un clic, directamente en la barra de menús de tu Mac.

Haz clic en el icono de la barra de menús para ver todas tus cámaras en una cuadrícula en vivo. Haz clic en una cámara para ampliarla y pulsa F para pantalla completa. Con las cámaras PTZ, gira e inclina con las teclas de flecha o el panel en pantalla.

QuickProtect se comunica directamente con tu controlador en tu red local mediante RTSP/RTSPS. Sin nube, sin cuenta, sin rastreo: tu vídeo nunca sale de tu red.

FUNCIONES
• Cuadrícula de cámaras en vivo en la barra de menús
• Ampliación y pantalla completa con un clic
• Control PTZ con el teclado o un panel en pantalla
• Zoom y desplazamiento dentro de una transmisión
• Ventana redimensionable, reordena las cámaras arrastrando
• Tamaño y ocultación por cámara
• Temas claro, oscuro y automático con colores de acento
• Atajo de teclado global para mostrar u ocultar la cuadrícula
• Abrir al iniciar sesión
• Gratis y de código abierto (MIT)

REQUISITOS
• Un controlador UniFi Protect en tu red local
• Una clave de la API de integración de tu controlador (para la lista de cámaras y las transmisiones en vivo)
• Una cuenta de administrador local: opcional, solo necesaria para el control PTZ

QuickProtect es una app independiente y no está afiliada a Ubiquiti Inc. ni respaldada por ella. UniFi y UniFi Protect son marcas de Ubiquiti Inc.
```

**What's New**
```
• Corregido un fallo en la vista general de transmisiones cuando varias transmisiones cambiaban a la vez.
• La ventana de cámaras ahora se cierra cuando cambias a otra app con Comando-Tab o el Dock.
• Las comprobaciones de actualización ya no anuncian una versión hasta que su compilación para Mac está disponible.
```

---

## 🇳🇱 Dutch (nl) — informal "je"

**App Name**
```
QuickProtect
```

**Subtitle**
```
Camera's in de menubalk
```

**Promotional Text**
```
Je UniFi Protect-camera's, één klik vanaf de menubalk. Live beelden, PTZ-bediening, volledig scherm — lokaal en privé. Geen cloud, geen account, geen tracking.
```

**Keywords**
```
UniFi,Protect,camera,beveiliging,bewaking,CCTV,NVR,RTSP,PTZ,menubalk,live,IP-camera
```

**Description**
```
QuickProtect zet je UniFi Protect-camera's op één klik afstand — direct in de menubalk van je Mac.

Klik op het menubalksymbool om al je camera's in een live raster te zien. Klik op een camera om die te vergroten en druk op F voor volledig scherm. PTZ-camera's pan en kantel je met de pijltoetsen of het bedieningspaneel op het scherm.

QuickProtect communiceert rechtstreeks met je controller op je lokale netwerk via RTSP/RTSPS. Geen cloud, geen account, geen tracking — je video verlaat nooit je netwerk.

FUNCTIES
• Live cameraraster in je menubalk
• Vergroten en volledig scherm met één klik
• PTZ-bediening met het toetsenbord of een paneel op het scherm
• Zoomen en pannen binnen een beeld
• Schaalbaar venster, camera's herschikken door slepen
• Formaat en zichtbaarheid per camera
• Lichte, donkere en automatische thema's met accentkleuren
• Globale sneltoets om het raster te tonen of te verbergen
• Starten bij inloggen
• Gratis en open source (MIT)

VEREISTEN
• Een UniFi Protect-controller op je lokale netwerk
• Een integratie-API-sleutel van je controller (voor de cameralijst en live streams)
• Een lokaal beheerdersaccount — optioneel, alleen nodig voor PTZ-bediening

QuickProtect is een onafhankelijke app en is niet verbonden met of goedgekeurd door Ubiquiti Inc. UniFi en UniFi Protect zijn handelsmerken van Ubiquiti Inc.
```

**What's New**
```
• Crash in het streamoverzicht verholpen wanneer meerdere camerastreams tegelijk wijzigden.
• Het venster met camera's sluit nu wanneer je met Command-Tab of via het Dock naar een andere app gaat.
• Updatecontroles melden een versie pas wanneer de Mac-versie ervan beschikbaar is.
```

---

## 🇮🇹 Italian (it) — informal "tu"

**App Name**
```
QuickProtect
```

**Subtitle**
```
Telecamere nella barra menu
```

**Promotional Text**
```
Le tue telecamere UniFi Protect, a un clic dalla barra dei menu. Feed dal vivo, controllo PTZ, schermo intero: locale e privato. Niente cloud, account o tracciamento.
```

**Keywords**
```
UniFi,Protect,telecamera,sicurezza,sorveglianza,CCTV,NVR,RTSP,PTZ,barra dei menu,IP
```

**Description**
```
QuickProtect mette le tue telecamere UniFi Protect a un clic di distanza, direttamente nella barra dei menu del tuo Mac.

Fai clic sull'icona nella barra dei menu per vedere tutte le telecamere in una griglia dal vivo. Fai clic su una telecamera per ingrandirla e premi F per lo schermo intero. Per le telecamere PTZ, effettua il brandeggio e l'inclinazione con i tasti freccia o il pad sullo schermo.

QuickProtect comunica direttamente con il tuo controller sulla rete locale tramite RTSP/RTSPS. Niente cloud, niente account, niente tracciamento: il tuo video non lascia mai la tua rete.

FUNZIONI
• Griglia di telecamere dal vivo nella barra dei menu
• Ingrandimento e schermo intero con un clic
• Controllo PTZ con la tastiera o un pad sullo schermo
• Zoom e spostamento all'interno di un feed
• Finestra ridimensionabile, riordina le telecamere trascinandole
• Dimensione e visibilità per ogni telecamera
• Temi chiaro, scuro e automatico con colori d'accento
• Scorciatoia da tastiera globale per mostrare o nascondere la griglia
• Avvio all'accesso
• Gratuito e open source (MIT)

REQUISITI
• Un controller UniFi Protect sulla tua rete locale
• Una chiave dell'API di integrazione del controller (per l'elenco delle telecamere e i flussi dal vivo)
• Un account amministratore locale — facoltativo, necessario solo per il controllo PTZ

QuickProtect è un'app indipendente e non è affiliata a Ubiquiti Inc. né approvata da quest'ultima. UniFi e UniFi Protect sono marchi di Ubiquiti Inc.
```

**What's New**
```
• Risolto un arresto anomalo nella panoramica dei flussi quando più flussi delle telecamere cambiavano contemporaneamente.
• La finestra delle telecamere ora si chiude quando passi a un'altra app con Comando-Tab o dal Dock.
• I controlli degli aggiornamenti non annunciano più una versione finché la relativa versione per Mac non è disponibile.
```

---

## 🇧🇷 Brazilian Portuguese (pt-BR) — "você"

**App Name**
```
QuickProtect
```

**Subtitle**
```
Câmeras na barra de menus
```

**Promotional Text**
```
Suas câmeras UniFi Protect, a um clique da barra de menus. Transmissões ao vivo, controle PTZ, tela cheia: tudo local e privado. Sem nuvem, sem conta, sem rastreamento.
```

**Keywords**
```
UniFi,Protect,câmera,segurança,vigilância,CCTV,NVR,RTSP,PTZ,barra de menus,câmera IP
```

**Description**
```
O QuickProtect coloca suas câmeras UniFi Protect a um clique de distância, direto na barra de menus do seu Mac.

Clique no ícone da barra de menus para ver todas as câmeras em uma grade ao vivo. Clique em uma câmera para ampliá-la e pressione F para tela cheia. Nas câmeras PTZ, use pan e tilt com as teclas de seta ou o painel na tela.

O QuickProtect se comunica diretamente com o seu controlador na rede local via RTSP/RTSPS. Sem nuvem, sem conta, sem rastreamento: seu vídeo nunca sai da sua rede.

RECURSOS
• Grade de câmeras ao vivo na barra de menus
• Ampliação e tela cheia com um clique
• Controle PTZ pelo teclado ou por um painel na tela
• Zoom e deslocamento dentro de uma transmissão
• Janela redimensionável, reordene as câmeras arrastando
• Tamanho e ocultação por câmera
• Temas claro, escuro e automático com cores de destaque
• Atalho de teclado global para mostrar ou ocultar a grade
• Abrir ao fazer login
• Gratuito e de código aberto (MIT)

REQUISITOS
• Um controlador UniFi Protect na sua rede local
• Uma chave da API de integração do seu controlador (para a lista de câmeras e as transmissões ao vivo)
• Uma conta de administrador local — opcional, necessária apenas para o controle PTZ

O QuickProtect é um app independente e não é afiliado nem endossado pela Ubiquiti Inc. UniFi e UniFi Protect são marcas comerciais da Ubiquiti Inc.
```

**What's New**
```
• Corrigida uma falha na visão geral das transmissões quando várias transmissões de câmera mudavam ao mesmo tempo.
• A janela de câmeras agora fecha quando você muda para outro app com Command-Tab ou pelo Dock.
• As verificações de atualização não anunciam mais uma versão até que a compilação para Mac esteja disponível.
```
