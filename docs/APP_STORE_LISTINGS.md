# Store Listings — QuickProtect

Localized store metadata for every language the app ships in
(en, de, fr, es, nl, it, pt-BR), for both stores:

- **Apple App Store** (macOS app) — first section below.
- **Microsoft Store** (Windows app) — [second section](#microsoft-store--windows) at the bottom.

# Apple App Store — macOS

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
• Open source (MIT)

REQUIREMENTS
• A UniFi Protect controller on your local network
• An Integration API key from your controller (for the camera list and live streams)
• A local admin account — optional, only needed for PTZ control

QuickProtect is an independent app and is not affiliated with or endorsed by Ubiquiti Inc. UniFi and UniFi Protect are trademarks of Ubiquiti Inc.
```

**What's New**
```
• Switching stream quality is now seamless — focusing a camera or going fullscreen no longer freezes the video for a moment.
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
• Quelloffen (MIT)

VORAUSSETZUNGEN
• Ein UniFi-Protect-Controller im lokalen Netzwerk
• Ein Integrations-API-Schlüssel deines Controllers (für die Kameraliste und Live-Streams)
• Ein lokales Admin-Konto – optional, nur für die PTZ-Steuerung nötig

QuickProtect ist eine unabhängige App und steht in keiner Verbindung zu Ubiquiti Inc. und wird von Ubiquiti Inc. nicht unterstützt. UniFi und UniFi Protect sind Marken von Ubiquiti Inc.
```

**What's New**
```
• Qualitätswechsel sind jetzt nahtlos – wenn du eine Kamera vergrößerst oder in den Vollbildmodus wechselst, friert das Video nicht mehr kurz ein.
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
• Open source (MIT)

CONFIGURATION REQUISE
• Un contrôleur UniFi Protect sur votre réseau local
• Une clé de l'API d'intégration de votre contrôleur (pour la liste des caméras et les flux en direct)
• Un compte administrateur local — facultatif, requis uniquement pour le contrôle PTZ

QuickProtect est une app indépendante, non affiliée à Ubiquiti Inc. ni approuvée par Ubiquiti Inc. UniFi et UniFi Protect sont des marques d'Ubiquiti Inc.
```

**What's New**
```
• Le changement de qualité du flux est désormais fluide : agrandir une caméra ou passer en plein écran ne fige plus la vidéo un instant.
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
• Código abierto (MIT)

REQUISITOS
• Un controlador UniFi Protect en tu red local
• Una clave de la API de integración de tu controlador (para la lista de cámaras y las transmisiones en vivo)
• Una cuenta de administrador local: opcional, solo necesaria para el control PTZ

QuickProtect es una app independiente y no está afiliada a Ubiquiti Inc. ni respaldada por ella. UniFi y UniFi Protect son marcas de Ubiquiti Inc.
```

**What's New**
```
• El cambio de calidad de la transmisión ahora es fluido: ampliar una cámara o pasar a pantalla completa ya no congela el vídeo por un momento.
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
• Open source (MIT)

VEREISTEN
• Een UniFi Protect-controller op je lokale netwerk
• Een integratie-API-sleutel van je controller (voor de cameralijst en live streams)
• Een lokaal beheerdersaccount — optioneel, alleen nodig voor PTZ-bediening

QuickProtect is een onafhankelijke app en is niet verbonden met of goedgekeurd door Ubiquiti Inc. UniFi en UniFi Protect zijn handelsmerken van Ubiquiti Inc.
```

**What's New**
```
• Wisselen van streamkwaliteit gaat nu naadloos — een camera vergroten of naar volledig scherm gaan bevriest het beeld niet meer even.
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
• Open source (MIT)

REQUISITI
• Un controller UniFi Protect sulla tua rete locale
• Una chiave dell'API di integrazione del controller (per l'elenco delle telecamere e i flussi dal vivo)
• Un account amministratore locale — facoltativo, necessario solo per il controllo PTZ

QuickProtect è un'app indipendente e non è affiliata a Ubiquiti Inc. né approvata da quest'ultima. UniFi e UniFi Protect sono marchi di Ubiquiti Inc.
```

**What's New**
```
• Il cambio di qualità del flusso ora è fluido: ingrandire una telecamera o passare a schermo intero non blocca più il video per un istante.
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
• Código aberto (MIT)

REQUISITOS
• Um controlador UniFi Protect na sua rede local
• Uma chave da API de integração do seu controlador (para a lista de câmeras e as transmissões ao vivo)
• Uma conta de administrador local — opcional, necessária apenas para o controle PTZ

O QuickProtect é um app independente e não é afiliado nem endossado pela Ubiquiti Inc. UniFi e UniFi Protect são marcas comerciais da Ubiquiti Inc.
```

**What's New**
```
• A troca de qualidade da transmissão agora é perfeita — ampliar uma câmera ou entrar em tela cheia não congela mais o vídeo por um instante.
```

---

# Microsoft Store — Windows

Copy each field into **Partner Center → Apps and games → QuickProtect →
Store listings → (language)**. The MSIX manifest declares all 7 languages,
so Partner Center expects a listing for each.

Partner Center field limits (per language):

| Field | Limit |
|---|---|
| Product name | reserved in Partner Center (not free text) |
| Description | 10,000 characters |
| What's new in this version | 1,500 characters (leave **blank** on the first submission — Partner Center guidance) |
| Product features | up to 20 entries, 200 characters each |
| Short description | 270 characters recommended (shown at the top of the listing) |
| Keywords | up to 7, 40 characters each, ≤21 separate words across all keywords |
| Copyright and trademark info | 200 characters |

Notes:
- **Partner Center is edited by hand; this file is the master copy.** Update
  here first, then paste into Partner Center with the next submission.
- **This is the paid build.** Per `PARITY.md` → Distribution, the Store MSIX is
  the paid channel; the free channel is the unsigned Inno Setup installer on
  GitHub releases. The copy therefore never calls the app *free* — it says
  *open source (MIT)*, and the description names what buying here adds
  (supporting development, automatic updates through the Store).
- **Minimum OS is Windows 10 1809 (build 17763), x64**, taken from
  `TargetDeviceFamily` in `dotnet/installer/msix/AppxManifest.xml`. If that
  manifest changes, change it here too.
- Register is per-language and matches the App Store listing: German, Spanish,
  Dutch, Italian informal; French formal *vous*; Brazilian Portuguese *você*.
- Windows wording differs from macOS on purpose: *system tray* instead of
  *menu bar*, *Start with Windows* instead of *Launch at login*. The Windows
  listing also mentions features the Mac copy omits (pinned always-on-top
  windows, snapshots, audio) — see docs/PARITY.md for the feature set.
- The **Description ends with the non-affiliation disclaimer** — required
  because UniFi / Ubiquiti trademarks appear in the metadata; keep it.
- **Product features** is a separate Partner Center field (the Store renders
  it as its own bulleted list), so the Description body does not repeat the
  feature list the way the App Store description does.
- **What's new** is per-release and platform-specific — replace it with each
  submission; never reuse the Mac release notes verbatim. It was left blank
  for the first submission (Partner Center asks for that), so the "Initial
  Microsoft Store release." lines below apply only if a first-submission note
  is ever wanted.
- **Copyright and trademark info** is the same line for every language
  (legal text, kept in English). It names **CB Group LLC**, matching the Store
  `PublisherDisplayName` and the organization account the app publishes under —
  deliberately *not* the MIT license holder in `LICENSE` (Christian Bartels),
  which is a separate legal attribution and stays unchanged:

```
© CB Group LLC. UniFi and UniFi Protect are trademarks of Ubiquiti Inc. QuickProtect is an independent app, not affiliated with or endorsed by Ubiquiti Inc.
```

---

## 🇬🇧 English (en) — primary

**Description**
```
QuickProtect puts your UniFi Protect cameras one click away — right in the Windows system tray.

Click the tray icon to see every camera in a live grid. Click a camera to focus it, press F for fullscreen or S for a snapshot. For PTZ cameras, pan and tilt with the arrow keys or the on-screen pad. Pin any camera as a compact always-on-top window.

QuickProtect talks directly to your controller on your local network over RTSP/RTSPS. No cloud, no account, no tracking — your video never leaves your network.

REQUIREMENTS
• A UniFi Protect controller on your local network
• An Integration API key from your controller (for the camera list and live streams)
• A local admin account — optional, only needed for PTZ control

QuickProtect is open source under the MIT license. Buying it here supports development and gets you automatic updates through the Microsoft Store.

QuickProtect is an independent app and is not affiliated with or endorsed by Ubiquiti Inc. UniFi and UniFi Protect are trademarks of Ubiquiti Inc.
```

**Product features**
```
• Live camera grid, one click from the system tray
• One-click focus and fullscreen
• PTZ control with the keyboard or an on-screen pad
• Digital zoom and pan within a feed
• Pin cameras as compact always-on-top windows
• Snapshots to the clipboard or a folder
• Audio for the focused camera (muted by default)
• Layout profiles; per-camera size, order and visibility
• Light, dark, and automatic themes with accent colors
• Global keyboard shortcut to show or hide the grid
• Start with Windows
• Open source (MIT)
```

**Short description**
```
Your UniFi Protect cameras, one click from the system tray. Live feeds, PTZ control, fullscreen — all local, all private. No cloud, no account, no tracking.
```

**Keywords**
```
UniFi Protect
camera viewer
security camera
CCTV
NVR
RTSP
PTZ
```

**What's New**
```
• Switching stream quality is now seamless — focusing a camera or going fullscreen no longer freezes the video for a moment.
• The focus view now shows its keyboard shortcuts as key hints.
```

---

## 🇩🇪 German (de)

**Description**
```
QuickProtect bringt deine UniFi-Protect-Kameras mit nur einem Klick in den Infobereich der Windows-Taskleiste.

Klicke auf das Taskleistensymbol, um alle Kameras in einem Live-Raster zu sehen. Klicke auf eine Kamera, um sie zu vergrößern, und drücke F für Vollbild oder S für einen Schnappschuss. PTZ-Kameras schwenkst und neigst du mit den Pfeiltasten oder dem Steuerkreuz auf dem Bildschirm. Einzelne Kameras kannst du als kompakte, immer im Vordergrund bleibende Fenster anheften.

QuickProtect kommuniziert direkt mit deinem Controller im lokalen Netzwerk über RTSP/RTSPS. Keine Cloud, kein Konto, kein Tracking – dein Video verlässt nie dein Netzwerk.

VORAUSSETZUNGEN
• Ein UniFi-Protect-Controller im lokalen Netzwerk
• Ein Integrations-API-Schlüssel deines Controllers (für die Kameraliste und Live-Streams)
• Ein lokales Admin-Konto – optional, nur für die PTZ-Steuerung nötig

QuickProtect ist quelloffen unter der MIT-Lizenz. Der Kauf hier unterstützt die Entwicklung und bringt dir automatische Updates über den Microsoft Store.

QuickProtect ist eine unabhängige App und steht in keiner Verbindung zu Ubiquiti Inc. und wird von Ubiquiti Inc. nicht unterstützt. UniFi und UniFi Protect sind Marken von Ubiquiti Inc.
```

**Product features**
```
• Live-Kameraraster, einen Klick vom Infobereich entfernt
• Großansicht und Vollbild mit einem Klick
• PTZ-Steuerung per Tastatur oder Steuerkreuz
• Digitaler Zoom und Schwenken im Bild
• Kameras als kompakte, immer im Vordergrund bleibende Fenster anheften
• Schnappschüsse in die Zwischenablage oder einen Ordner
• Ton für die fokussierte Kamera (standardmäßig stumm)
• Layout-Profile; Größe, Reihenfolge und Sichtbarkeit pro Kamera
• Helles, dunkles und automatisches Design mit Akzentfarben
• Globaler Kurzbefehl zum Ein- und Ausblenden des Rasters
• Automatisch mit Windows starten
• Quelloffen (MIT)
```

**Short description**
```
Deine UniFi-Protect-Kameras, nur einen Klick von der Taskleiste entfernt. Live-Feeds, PTZ-Steuerung, Vollbild – alles lokal und privat. Keine Cloud, kein Konto, kein Tracking.
```

**Keywords**
```
UniFi Protect
Kamera
Überwachungskamera
CCTV
NVR
RTSP
PTZ
```

**What's New**
```
• Qualitätswechsel sind jetzt nahtlos – wenn du eine Kamera vergrößerst oder in den Vollbildmodus wechselst, friert das Video nicht mehr kurz ein.
• Die Großansicht zeigt jetzt ihre Tastaturkürzel als Tastenhinweise an.
```

---

## 🇫🇷 French (fr) — formal "vous"

**Description**
```
QuickProtect place vos caméras UniFi Protect à un clic — directement dans la zone de notification de Windows.

Cliquez sur l'icône de la zone de notification pour voir toutes vos caméras dans une grille en direct. Cliquez sur une caméra pour l'agrandir, appuyez sur F pour le plein écran ou sur S pour une capture. Pour les caméras PTZ, effectuez un panoramique et inclinez avec les touches fléchées ou le pavé à l'écran. Épinglez une caméra dans une fenêtre compacte toujours au premier plan.

QuickProtect communique directement avec votre contrôleur sur votre réseau local via RTSP/RTSPS. Pas de cloud, pas de compte, pas de suivi — votre vidéo ne quitte jamais votre réseau.

CONFIGURATION REQUISE
• Un contrôleur UniFi Protect sur votre réseau local
• Une clé de l'API d'intégration de votre contrôleur (pour la liste des caméras et les flux en direct)
• Un compte administrateur local — facultatif, requis uniquement pour le contrôle PTZ

QuickProtect est open source sous licence MIT. L'acheter ici soutient le développement et vous donne les mises à jour automatiques via le Microsoft Store.

QuickProtect est une app indépendante, non affiliée à Ubiquiti Inc. ni approuvée par Ubiquiti Inc. UniFi et UniFi Protect sont des marques d'Ubiquiti Inc.
```

**Product features**
```
• Grille de caméras en direct, à un clic de la zone de notification
• Agrandissement et plein écran en un clic
• Contrôle PTZ au clavier ou avec un pavé à l'écran
• Zoom numérique et panoramique dans un flux
• Caméras épinglables en fenêtres compactes toujours au premier plan
• Captures dans le presse-papiers ou un dossier
• Audio pour la caméra agrandie (coupé par défaut)
• Profils de disposition ; taille, ordre et visibilité par caméra
• Thèmes clair, sombre et automatique avec couleurs d'accent
• Raccourci clavier global pour afficher ou masquer la grille
• Démarrage avec Windows
• Open source (MIT)
```

**Short description**
```
Vos caméras UniFi Protect, à un clic de la zone de notification. Flux en direct, contrôle PTZ, plein écran — tout en local et privé. Pas de cloud, pas de compte, pas de suivi.
```

**Keywords**
```
UniFi Protect
caméra
caméra de sécurité
vidéosurveillance
NVR
RTSP
PTZ
```

**What's New**
```
• Le changement de qualité du flux est désormais fluide : agrandir une caméra ou passer en plein écran ne fige plus la vidéo un instant.
• La vue agrandie affiche désormais ses raccourcis clavier sous forme de touches.
```

---

## 🇪🇸 Spanish (es) — informal "tú"

**Description**
```
QuickProtect pone tus cámaras UniFi Protect a un clic, directamente en la bandeja del sistema de Windows.

Haz clic en el icono de la bandeja para ver todas tus cámaras en una cuadrícula en vivo. Haz clic en una cámara para ampliarla, pulsa F para pantalla completa o S para una captura. Con las cámaras PTZ, gira e inclina con las teclas de flecha o el panel en pantalla. Fija cámaras como ventanas compactas siempre en primer plano.

QuickProtect se comunica directamente con tu controlador en tu red local mediante RTSP/RTSPS. Sin nube, sin cuenta, sin rastreo: tu vídeo nunca sale de tu red.

REQUISITOS
• Un controlador UniFi Protect en tu red local
• Una clave de la API de integración de tu controlador (para la lista de cámaras y las transmisiones en vivo)
• Una cuenta de administrador local: opcional, solo necesaria para el control PTZ

QuickProtect es de código abierto con licencia MIT. Comprarlo aquí apoya el desarrollo y te da actualizaciones automáticas a través de Microsoft Store.

QuickProtect es una app independiente y no está afiliada a Ubiquiti Inc. ni respaldada por ella. UniFi y UniFi Protect son marcas de Ubiquiti Inc.
```

**Product features**
```
• Cuadrícula de cámaras en vivo, a un clic de la bandeja del sistema
• Ampliación y pantalla completa con un clic
• Control PTZ con el teclado o un panel en pantalla
• Zoom digital y desplazamiento dentro de una transmisión
• Fija cámaras como ventanas compactas siempre en primer plano
• Capturas al portapapeles o a una carpeta
• Audio de la cámara ampliada (silenciado por defecto)
• Perfiles de diseño; tamaño, orden y visibilidad por cámara
• Temas claro, oscuro y automático con colores de acento
• Atajo de teclado global para mostrar u ocultar la cuadrícula
• Iniciar con Windows
• Código abierto (MIT)
```

**Short description**
```
Tus cámaras UniFi Protect, a un clic de la bandeja del sistema. Transmisiones en vivo, control PTZ, pantalla completa: todo local y privado. Sin nube, sin cuenta, sin rastreo.
```

**Keywords**
```
UniFi Protect
cámara
cámara de seguridad
videovigilancia
NVR
RTSP
PTZ
```

**What's New**
```
• El cambio de calidad de la transmisión ahora es fluido: ampliar una cámara o pasar a pantalla completa ya no congela el vídeo por un momento.
• La vista ampliada ahora muestra sus atajos de teclado como indicaciones de teclas.
```

---

## 🇳🇱 Dutch (nl) — informal "je"

**Description**
```
QuickProtect zet je UniFi Protect-camera's op één klik afstand — direct in het systeemvak van Windows.

Klik op het systeemvakpictogram om al je camera's in een live raster te zien. Klik op een camera om die te vergroten en druk op F voor volledig scherm of S voor een momentopname. PTZ-camera's pan en kantel je met de pijltoetsen of het bedieningspaneel op het scherm. Zet camera's vast als compacte vensters die altijd op de voorgrond blijven.

QuickProtect communiceert rechtstreeks met je controller op je lokale netwerk via RTSP/RTSPS. Geen cloud, geen account, geen tracking — je video verlaat nooit je netwerk.

VEREISTEN
• Een UniFi Protect-controller op je lokale netwerk
• Een integratie-API-sleutel van je controller (voor de cameralijst en live streams)
• Een lokaal beheerdersaccount — optioneel, alleen nodig voor PTZ-bediening

QuickProtect is open source onder de MIT-licentie. Het hier kopen steunt de ontwikkeling en geeft je automatische updates via de Microsoft Store.

QuickProtect is een onafhankelijke app en is niet verbonden met of goedgekeurd door Ubiquiti Inc. UniFi en UniFi Protect zijn handelsmerken van Ubiquiti Inc.
```

**Product features**
```
• Live cameraraster, één klik vanaf het systeemvak
• Vergroten en volledig scherm met één klik
• PTZ-bediening met het toetsenbord of een paneel op het scherm
• Digitale zoom en pannen binnen een beeld
• Camera's vastzetten als compacte vensters altijd op de voorgrond
• Momentopnamen naar het klembord of een map
• Audio voor de vergrote camera (standaard gedempt)
• Indelingsprofielen; formaat, volgorde en zichtbaarheid per camera
• Lichte, donkere en automatische thema's met accentkleuren
• Globale sneltoets om het raster te tonen of te verbergen
• Starten met Windows
• Open source (MIT)
```

**Short description**
```
Je UniFi Protect-camera's, één klik vanaf het systeemvak. Live beelden, PTZ-bediening, volledig scherm — lokaal en privé. Geen cloud, geen account, geen tracking.
```

**Keywords**
```
UniFi Protect
camera
beveiligingscamera
bewaking
NVR
RTSP
PTZ
```

**What's New**
```
• Wisselen van streamkwaliteit gaat nu naadloos — een camera vergroten of naar volledig scherm gaan bevriest het beeld niet meer even.
• De vergrote weergave toont nu de sneltoetsen als toetshints.
```

---

## 🇮🇹 Italian (it) — informal "tu"

**Description**
```
QuickProtect mette le tue telecamere UniFi Protect a un clic di distanza, direttamente nell'area di notifica di Windows.

Fai clic sull'icona nell'area di notifica per vedere tutte le telecamere in una griglia dal vivo. Fai clic su una telecamera per ingrandirla, premi F per lo schermo intero o S per un'istantanea. Per le telecamere PTZ, effettua il brandeggio e l'inclinazione con i tasti freccia o il pad sullo schermo. Fissa le telecamere come finestre compatte sempre in primo piano.

QuickProtect comunica direttamente con il tuo controller sulla rete locale tramite RTSP/RTSPS. Niente cloud, niente account, niente tracciamento: il tuo video non lascia mai la tua rete.

REQUISITI
• Un controller UniFi Protect sulla tua rete locale
• Una chiave dell'API di integrazione del controller (per l'elenco delle telecamere e i flussi dal vivo)
• Un account amministratore locale — facoltativo, necessario solo per il controllo PTZ

QuickProtect è open source con licenza MIT. Acquistarlo qui sostiene lo sviluppo e ti offre gli aggiornamenti automatici tramite Microsoft Store.

QuickProtect è un'app indipendente e non è affiliata a Ubiquiti Inc. né approvata da quest'ultima. UniFi e UniFi Protect sono marchi di Ubiquiti Inc.
```

**Product features**
```
• Griglia di telecamere dal vivo, a un clic dall'area di notifica
• Ingrandimento e schermo intero con un clic
• Controllo PTZ con la tastiera o un pad sullo schermo
• Zoom digitale e spostamento all'interno di un feed
• Telecamere fissabili come finestre compatte sempre in primo piano
• Istantanee negli appunti o in una cartella
• Audio per la telecamera ingrandita (disattivato per impostazione predefinita)
• Profili di layout; dimensione, ordine e visibilità per telecamera
• Temi chiaro, scuro e automatico con colori d'accento
• Scorciatoia da tastiera globale per mostrare o nascondere la griglia
• Avvio con Windows
• Open source (MIT)
```

**Short description**
```
Le tue telecamere UniFi Protect, a un clic dall'area di notifica. Feed dal vivo, controllo PTZ, schermo intero: locale e privato. Niente cloud, account o tracciamento.
```

**Keywords**
```
UniFi Protect
telecamera
telecamera di sicurezza
videosorveglianza
NVR
RTSP
PTZ
```

**What's New**
```
• Il cambio di qualità del flusso ora è fluido: ingrandire una telecamera o passare a schermo intero non blocca più il video per un istante.
• La vista ingrandita ora mostra le scorciatoie da tastiera come suggerimenti dei tasti.
```

---

## 🇧🇷 Brazilian Portuguese (pt-BR) — "você"

**Description**
```
O QuickProtect coloca suas câmeras UniFi Protect a um clique de distância, direto na bandeja do sistema do Windows.

Clique no ícone da bandeja para ver todas as câmeras em uma grade ao vivo. Clique em uma câmera para ampliá-la, pressione F para tela cheia ou S para um instantâneo. Nas câmeras PTZ, use pan e tilt com as teclas de seta ou o painel na tela. Fixe câmeras como janelas compactas sempre em primeiro plano.

O QuickProtect se comunica diretamente com o seu controlador na rede local via RTSP/RTSPS. Sem nuvem, sem conta, sem rastreamento: seu vídeo nunca sai da sua rede.

REQUISITOS
• Um controlador UniFi Protect na sua rede local
• Uma chave da API de integração do seu controlador (para a lista de câmeras e as transmissões ao vivo)
• Uma conta de administrador local — opcional, necessária apenas para o controle PTZ

O QuickProtect é de código aberto sob a licença MIT. Comprá-lo aqui apoia o desenvolvimento e garante atualizações automáticas pela Microsoft Store.

O QuickProtect é um app independente e não é afiliado nem endossado pela Ubiquiti Inc. UniFi e UniFi Protect são marcas comerciais da Ubiquiti Inc.
```

**Product features**
```
• Grade de câmeras ao vivo, a um clique da bandeja do sistema
• Ampliação e tela cheia com um clique
• Controle PTZ pelo teclado ou por um painel na tela
• Zoom digital e deslocamento dentro de uma transmissão
• Fixe câmeras como janelas compactas sempre em primeiro plano
• Instantâneos para a área de transferência ou uma pasta
• Áudio da câmera ampliada (silenciado por padrão)
• Perfis de layout; tamanho, ordem e visibilidade por câmera
• Temas claro, escuro e automático com cores de destaque
• Atalho de teclado global para mostrar ou ocultar a grade
• Iniciar com o Windows
• Código aberto (MIT)
```

**Short description**
```
Suas câmeras UniFi Protect, a um clique da bandeja do sistema. Transmissões ao vivo, controle PTZ, tela cheia: tudo local e privado. Sem nuvem, sem conta, sem rastreamento.
```

**Keywords**
```
UniFi Protect
câmera
câmera de segurança
videomonitoramento
NVR
RTSP
PTZ
```

**What's New**
```
• A troca de qualidade da transmissão agora é perfeita — ampliar uma câmera ou entrar em tela cheia não congela mais o vídeo por um instante.
• A visualização ampliada agora mostra os atalhos de teclado como dicas de teclas.
```
