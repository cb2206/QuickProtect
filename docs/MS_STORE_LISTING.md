# Microsoft Store Listing — QuickProtect

Localized Microsoft Store metadata for every language the app ships in.
Copy each field into **Partner Center → QuickProtect → Store listings → (language)**.

Partner Center field limits (per language):

| Field | Limit |
|---|---|
| Product name | reserved in Partner Center (not free text) |
| Short description | 1,000 characters |
| Description | 10,000 characters |
| What's new in this version | 1,500 characters |
| Search terms | 7 terms, 30 characters each |
| Copyright and trademark info | 200 characters |

Re-check these in Partner Center before pasting; Microsoft has changed them before.

Notes:
- **This is the paid build.** Per [`PARITY.md`](PARITY.md) → Distribution, the Store
  MSIX is the paid channel and the unsigned Inno Setup installer on GitHub is the
  free one. So the copy must **not** repeat the App Store listing's "Free and
  open-source" bullet — it says *open source*, and names what buying here adds
  (Store-signed, automatic updates, no SmartScreen prompt).
- **Wording is Windows-native, not translated Mac copy.** "Menu bar" becomes the
  system tray / notification area in each language, and "your Mac" becomes "your PC".
  The panel opens at the tray corner, not under a menu-bar item (`PARITY.md`).
- Each description ends with the same **non-affiliation disclaimer** as the App
  Store listing — required wherever the UniFi / Ubiquiti trademarks appear. Keep it.
- **Minimum OS is Windows 10 1809 (build 17763), x64**, taken from
  `TargetDeviceFamily` in `dotnet/installer/msix/AppxManifest.xml`. If that
  manifest changes, change it here too.
- Register is per-language and matches the App Store listing: German, Spanish,
  Dutch, Italian informal; French formal *vous*; Brazilian Portuguese *você*.
- **Copyright line names CB Group LLC**, matching the Store
  `PublisherDisplayName` and the organization account the app publishes under.
  This is deliberately *not* the MIT license holder in `LICENSE` (Christian
  Bartels), which is a separate legal attribution and stays unchanged.

---

## 🇬🇧 English (en) — primary

**Short description**
```
Your UniFi Protect cameras, one click from the Windows system tray. Live feeds, PTZ control, audio, snapshots and fullscreen — all on your local network. No cloud, no account, no tracking.
```

**Description**
```
QuickProtect puts your UniFi Protect cameras one click away — right in your Windows system tray.

Click the tray icon to see every camera in a live grid. Click a camera to focus it, and press F for fullscreen. For PTZ cameras, pan and tilt with the arrow keys or the on-screen pad.

QuickProtect talks directly to your controller on your local network over RTSP/RTSPS, decoding H.264 and H.265 with a built-in video engine. No cloud, no account, no tracking — your video never leaves your network.

FEATURES
• Live camera grid in the system tray
• One-click focus and fullscreen
• PTZ control with the keyboard or an on-screen pad
• Digital zoom and pan within a feed
• Audio playback with one-key mute
• Snapshots to the clipboard or a folder
• Pinned always-on-top camera windows
• Secondary-lens picture-in-picture — for example the package camera on a doorbell
• Layout profiles for camera visibility, size, and order
• Resizable panel, drag to reorder cameras
• Global keyboard shortcut to show or hide the panel
• Light, dark, and automatic themes with accent colors
• Seven languages
• Launch at login

REQUIREMENTS
• Windows 10 version 1809 (64-bit) or later
• A UniFi Protect controller on your local network
• An Integration API key from your controller (for the camera list and live streams)
• A local admin account — optional, only needed for PTZ control

QuickProtect is open source under the MIT license. Buying it here supports development and gets you automatic updates through the Microsoft Store.

QuickProtect is an independent app and is not affiliated with or endorsed by Ubiquiti Inc. UniFi and UniFi Protect are trademarks of Ubiquiti Inc.
```

**What's new in this version**
```
First Windows release of QuickProtect, matching the Mac app feature for feature: live camera grid, focus view with fullscreen, PTZ control, digital zoom, audio, snapshots, pinned always-on-top windows, layout profiles, global hotkey, and seven languages.
```

**Search terms**
```
UniFi | Protect | security camera | IP camera | NVR | RTSP | PTZ
```

**Copyright and trademark info**
```
© 2026 CB Group LLC. UniFi and UniFi Protect are trademarks of Ubiquiti Inc.
```

---

## 🇩🇪 German (de)

**Short description**
```
Deine UniFi-Protect-Kameras, nur einen Klick vom Infobereich der Taskleiste entfernt. Live-Feeds, PTZ-Steuerung, Ton, Schnappschüsse und Vollbild – alles im lokalen Netzwerk. Keine Cloud, kein Konto, kein Tracking.
```

**Description**
```
QuickProtect bringt deine UniFi-Protect-Kameras mit nur einem Klick direkt in den Infobereich deiner Windows-Taskleiste.

Klicke auf das Taskleistensymbol, um alle Kameras in einem Live-Raster zu sehen. Klicke auf eine Kamera, um sie zu vergrößern, und drücke F für Vollbild. PTZ-Kameras schwenkst und neigst du mit den Pfeiltasten oder dem Steuerkreuz auf dem Bildschirm.

QuickProtect kommuniziert direkt mit deinem Controller im lokalen Netzwerk über RTSP/RTSPS und dekodiert H.264 und H.265 mit einer integrierten Video-Engine. Keine Cloud, kein Konto, kein Tracking – dein Video verlässt nie dein Netzwerk.

FUNKTIONEN
• Live-Kameraraster im Infobereich der Taskleiste
• Großansicht und Vollbild mit einem Klick
• PTZ-Steuerung per Tastatur oder Steuerkreuz
• Digitaler Zoom und Schwenken im Bild
• Tonwiedergabe mit Stummschaltung per Tastendruck
• Schnappschüsse in die Zwischenablage oder in einen Ordner
• Angeheftete Kamerafenster, immer im Vordergrund
• Bild-in-Bild der zweiten Linse – zum Beispiel die Paketkamera einer Türklingel
• Layout-Profile für Sichtbarkeit, Größe und Reihenfolge der Kameras
• Größenveränderbares Fenster, Kameras per Ziehen neu anordnen
• Globaler Kurzbefehl zum Ein- und Ausblenden des Fensters
• Helles, dunkles und automatisches Design mit Akzentfarben
• Sieben Sprachen
• Beim Anmelden starten

VORAUSSETZUNGEN
• Windows 10 Version 1809 (64 Bit) oder neuer
• Ein UniFi-Protect-Controller im lokalen Netzwerk
• Ein Integrations-API-Schlüssel deines Controllers (für die Kameraliste und Live-Streams)
• Ein lokales Admin-Konto – optional, nur für die PTZ-Steuerung nötig

QuickProtect ist quelloffen unter der MIT-Lizenz. Der Kauf hier unterstützt die Entwicklung und bringt dir automatische Updates über den Microsoft Store.

QuickProtect ist eine unabhängige App und steht in keiner Verbindung zu Ubiquiti Inc. und wird von Ubiquiti Inc. nicht unterstützt. UniFi und UniFi Protect sind Marken von Ubiquiti Inc.
```

**What's new in this version**
```
Erste Windows-Version von QuickProtect – mit demselben Funktionsumfang wie die Mac-App: Live-Kameraraster, Großansicht mit Vollbild, PTZ-Steuerung, digitaler Zoom, Ton, Schnappschüsse, angeheftete Fenster, Layout-Profile, globaler Kurzbefehl und sieben Sprachen.
```

**Search terms**
```
UniFi | Protect | Überwachungskamera | IP-Kamera | NVR | RTSP | PTZ
```

**Copyright and trademark info**
```
© 2026 CB Group LLC. UniFi und UniFi Protect sind Marken von Ubiquiti Inc.
```

---

## 🇫🇷 French (fr) — formal "vous"

**Short description**
```
Vos caméras UniFi Protect, à un clic de la zone de notification de Windows. Flux en direct, contrôle PTZ, audio, captures et plein écran — tout sur votre réseau local. Pas de cloud, pas de compte, pas de suivi.
```

**Description**
```
QuickProtect place vos caméras UniFi Protect à un clic — directement dans la zone de notification de Windows.

Cliquez sur l'icône de la barre des tâches pour voir toutes vos caméras dans une grille en direct. Cliquez sur une caméra pour l'agrandir et appuyez sur F pour le plein écran. Pour les caméras PTZ, effectuez un panoramique et inclinez avec les touches fléchées ou le pavé à l'écran.

QuickProtect communique directement avec votre contrôleur sur votre réseau local via RTSP/RTSPS et décode le H.264 et le H.265 avec un moteur vidéo intégré. Pas de cloud, pas de compte, pas de suivi — votre vidéo ne quitte jamais votre réseau.

FONCTIONNALITÉS
• Grille de caméras en direct dans la zone de notification
• Agrandissement et plein écran en un clic
• Contrôle PTZ au clavier ou avec un pavé à l'écran
• Zoom numérique et panoramique dans un flux
• Lecture audio avec coupure du son en une touche
• Captures vers le presse-papiers ou un dossier
• Fenêtres de caméra épinglées, toujours au premier plan
• Incrustation d'image de l'objectif secondaire — par exemple la caméra colis d'une sonnette
• Profils de disposition pour la visibilité, la taille et l'ordre des caméras
• Fenêtre redimensionnable, réorganisation des caméras par glissement
• Raccourci clavier global pour afficher ou masquer la fenêtre
• Thèmes clair, sombre et automatique avec couleurs d'accent
• Sept langues
• Lancement à la connexion

CONFIGURATION REQUISE
• Windows 10 version 1809 (64 bits) ou ultérieur
• Un contrôleur UniFi Protect sur votre réseau local
• Une clé de l'API d'intégration de votre contrôleur (pour la liste des caméras et les flux en direct)
• Un compte administrateur local — facultatif, requis uniquement pour le contrôle PTZ

QuickProtect est open source sous licence MIT. L'acheter ici soutient le développement et vous donne les mises à jour automatiques via le Microsoft Store.

QuickProtect est une app indépendante, non affiliée à Ubiquiti Inc. ni approuvée par Ubiquiti Inc. UniFi et UniFi Protect sont des marques d'Ubiquiti Inc.
```

**What's new in this version**
```
Première version Windows de QuickProtect, avec les mêmes fonctionnalités que l'app Mac : grille de caméras en direct, vue agrandie avec plein écran, contrôle PTZ, zoom numérique, audio, captures, fenêtres épinglées, profils de disposition, raccourci global et sept langues.
```

**Search terms**
```
UniFi | Protect | caméra de sécurité | caméra IP | NVR | RTSP | PTZ
```

**Copyright and trademark info**
```
© 2026 CB Group LLC. UniFi et UniFi Protect sont des marques d'Ubiquiti Inc.
```

---

## 🇪🇸 Spanish (es) — informal "tú"

**Short description**
```
Tus cámaras UniFi Protect, a un clic del área de notificación de Windows. Transmisiones en vivo, control PTZ, audio, capturas y pantalla completa: todo en tu red local. Sin nube, sin cuenta, sin rastreo.
```

**Description**
```
QuickProtect pone tus cámaras UniFi Protect a un clic, directamente en el área de notificación de Windows.

Haz clic en el icono de la barra de tareas para ver todas tus cámaras en una cuadrícula en vivo. Haz clic en una cámara para ampliarla y pulsa F para pantalla completa. Con las cámaras PTZ, gira e inclina con las teclas de flecha o el panel en pantalla.

QuickProtect se comunica directamente con tu controlador en tu red local mediante RTSP/RTSPS y decodifica H.264 y H.265 con un motor de vídeo integrado. Sin nube, sin cuenta, sin rastreo: tu vídeo nunca sale de tu red.

FUNCIONES
• Cuadrícula de cámaras en vivo en el área de notificación
• Ampliación y pantalla completa con un clic
• Control PTZ con el teclado o un panel en pantalla
• Zoom digital y desplazamiento dentro de una transmisión
• Reproducción de audio con silencio en una tecla
• Capturas al portapapeles o a una carpeta
• Ventanas de cámara ancladas, siempre visibles
• Imagen en imagen de la lente secundaria: por ejemplo, la cámara de paquetes de un timbre
• Perfiles de diseño para visibilidad, tamaño y orden de las cámaras
• Ventana redimensionable, reordena las cámaras arrastrando
• Atajo de teclado global para mostrar u ocultar la ventana
• Temas claro, oscuro y automático con colores de acento
• Siete idiomas
• Abrir al iniciar sesión

REQUISITOS
• Windows 10 versión 1809 (64 bits) o posterior
• Un controlador UniFi Protect en tu red local
• Una clave de la API de integración de tu controlador (para la lista de cámaras y las transmisiones en vivo)
• Una cuenta de administrador local: opcional, solo necesaria para el control PTZ

QuickProtect es de código abierto con licencia MIT. Comprarlo aquí apoya el desarrollo y te da actualizaciones automáticas a través de Microsoft Store.

QuickProtect es una app independiente y no está afiliada a Ubiquiti Inc. ni respaldada por ella. UniFi y UniFi Protect son marcas de Ubiquiti Inc.
```

**What's new in this version**
```
Primera versión para Windows de QuickProtect, con las mismas funciones que la app para Mac: cuadrícula de cámaras en vivo, vista ampliada con pantalla completa, control PTZ, zoom digital, audio, capturas, ventanas ancladas, perfiles de diseño, atajo global y siete idiomas.
```

**Search terms**
```
UniFi | Protect | cámara de seguridad | cámara IP | NVR | RTSP | PTZ
```

**Copyright and trademark info**
```
© 2026 CB Group LLC. UniFi y UniFi Protect son marcas de Ubiquiti Inc.
```

---

## 🇳🇱 Dutch (nl) — informal "je"

**Short description**
```
Je UniFi Protect-camera's, één klik vanaf het systeemvak van Windows. Live beelden, PTZ-bediening, geluid, momentopnamen en volledig scherm — allemaal op je lokale netwerk. Geen cloud, geen account, geen tracking.
```

**Description**
```
QuickProtect zet je UniFi Protect-camera's op één klik afstand — direct in het systeemvak van Windows.

Klik op het pictogram in het systeemvak om al je camera's in een live raster te zien. Klik op een camera om die te vergroten en druk op F voor volledig scherm. PTZ-camera's pan en kantel je met de pijltoetsen of het bedieningspaneel op het scherm.

QuickProtect communiceert rechtstreeks met je controller op je lokale netwerk via RTSP/RTSPS en decodeert H.264 en H.265 met een ingebouwde video-engine. Geen cloud, geen account, geen tracking — je video verlaat nooit je netwerk.

FUNCTIES
• Live cameraraster in het systeemvak
• Vergroten en volledig scherm met één klik
• PTZ-bediening met het toetsenbord of een paneel op het scherm
• Digitale zoom en pannen binnen een beeld
• Geluidsweergave met dempen via één toets
• Momentopnamen naar het klembord of een map
• Vastgezette cameravensters, altijd op de voorgrond
• Beeld-in-beeld van de tweede lens — bijvoorbeeld de pakketcamera van een deurbel
• Lay-outprofielen voor zichtbaarheid, formaat en volgorde van camera's
• Schaalbaar venster, camera's herschikken door slepen
• Globale sneltoets om het venster te tonen of te verbergen
• Lichte, donkere en automatische thema's met accentkleuren
• Zeven talen
• Starten bij inloggen

VEREISTEN
• Windows 10 versie 1809 (64-bit) of nieuwer
• Een UniFi Protect-controller op je lokale netwerk
• Een integratie-API-sleutel van je controller (voor de cameralijst en live streams)
• Een lokaal beheerdersaccount — optioneel, alleen nodig voor PTZ-bediening

QuickProtect is open source onder de MIT-licentie. Het hier kopen steunt de ontwikkeling en geeft je automatische updates via de Microsoft Store.

QuickProtect is een onafhankelijke app en is niet verbonden met of goedgekeurd door Ubiquiti Inc. UniFi en UniFi Protect zijn handelsmerken van Ubiquiti Inc.
```

**What's new in this version**
```
Eerste Windows-versie van QuickProtect, met dezelfde functies als de Mac-app: live cameraraster, vergrote weergave met volledig scherm, PTZ-bediening, digitale zoom, geluid, momentopnamen, vastgezette vensters, lay-outprofielen, globale sneltoets en zeven talen.
```

**Search terms**
```
UniFi | Protect | beveiligingscamera | IP-camera | NVR | RTSP | PTZ
```

**Copyright and trademark info**
```
© 2026 CB Group LLC. UniFi en UniFi Protect zijn handelsmerken van Ubiquiti Inc.
```

---

## 🇮🇹 Italian (it) — informal "tu"

**Short description**
```
Le tue telecamere UniFi Protect, a un clic dall'area di notifica di Windows. Feed dal vivo, controllo PTZ, audio, istantanee e schermo intero: tutto sulla tua rete locale. Niente cloud, account o tracciamento.
```

**Description**
```
QuickProtect mette le tue telecamere UniFi Protect a un clic di distanza, direttamente nell'area di notifica di Windows.

Fai clic sull'icona nella barra delle applicazioni per vedere tutte le telecamere in una griglia dal vivo. Fai clic su una telecamera per ingrandirla e premi F per lo schermo intero. Per le telecamere PTZ, effettua il brandeggio e l'inclinazione con i tasti freccia o il pad sullo schermo.

QuickProtect comunica direttamente con il tuo controller sulla rete locale tramite RTSP/RTSPS e decodifica H.264 e H.265 con un motore video integrato. Niente cloud, niente account, niente tracciamento: il tuo video non lascia mai la tua rete.

FUNZIONI
• Griglia di telecamere dal vivo nell'area di notifica
• Ingrandimento e schermo intero con un clic
• Controllo PTZ con la tastiera o un pad sullo schermo
• Zoom digitale e spostamento all'interno di un feed
• Riproduzione audio con disattivazione con un tasto
• Istantanee negli appunti o in una cartella
• Finestre delle telecamere fissate, sempre in primo piano
• Picture-in-picture della lente secondaria — per esempio la telecamera pacchi di un videocitofono
• Profili di layout per visibilità, dimensione e ordine delle telecamere
• Finestra ridimensionabile, riordina le telecamere trascinandole
• Scorciatoia da tastiera globale per mostrare o nascondere la finestra
• Temi chiaro, scuro e automatico con colori d'accento
• Sette lingue
• Avvio all'accesso

REQUISITI
• Windows 10 versione 1809 (64 bit) o successivo
• Un controller UniFi Protect sulla tua rete locale
• Una chiave dell'API di integrazione del controller (per l'elenco delle telecamere e i flussi dal vivo)
• Un account amministratore locale — facoltativo, necessario solo per il controllo PTZ

QuickProtect è open source con licenza MIT. Acquistarlo qui sostiene lo sviluppo e ti offre gli aggiornamenti automatici tramite Microsoft Store.

QuickProtect è un'app indipendente e non è affiliata a Ubiquiti Inc. né approvata da quest'ultima. UniFi e UniFi Protect sono marchi di Ubiquiti Inc.
```

**What's new in this version**
```
Prima versione Windows di QuickProtect, con le stesse funzioni dell'app per Mac: griglia di telecamere dal vivo, vista ingrandita con schermo intero, controllo PTZ, zoom digitale, audio, istantanee, finestre fissate, profili di layout, scorciatoia globale e sette lingue.
```

**Search terms**
```
UniFi | Protect | telecamera sicurezza | telecamera IP | NVR | RTSP | PTZ
```

**Copyright and trademark info**
```
© 2026 CB Group LLC. UniFi e UniFi Protect sono marchi di Ubiquiti Inc.
```

---

## 🇧🇷 Brazilian Portuguese (pt-BR) — "você"

**Short description**
```
Suas câmeras UniFi Protect, a um clique da área de notificação do Windows. Transmissões ao vivo, controle PTZ, áudio, capturas e tela cheia: tudo na sua rede local. Sem nuvem, sem conta, sem rastreamento.
```

**Description**
```
O QuickProtect coloca suas câmeras UniFi Protect a um clique de distância, direto na área de notificação do Windows.

Clique no ícone da barra de tarefas para ver todas as câmeras em uma grade ao vivo. Clique em uma câmera para ampliá-la e pressione F para tela cheia. Nas câmeras PTZ, use pan e tilt com as teclas de seta ou o painel na tela.

O QuickProtect se comunica diretamente com o seu controlador na rede local via RTSP/RTSPS e decodifica H.264 e H.265 com um motor de vídeo integrado. Sem nuvem, sem conta, sem rastreamento: seu vídeo nunca sai da sua rede.

RECURSOS
• Grade de câmeras ao vivo na área de notificação
• Ampliação e tela cheia com um clique
• Controle PTZ pelo teclado ou por um painel na tela
• Zoom digital e deslocamento dentro de uma transmissão
• Reprodução de áudio com mudo em uma tecla
• Capturas para a área de transferência ou uma pasta
• Janelas de câmera fixadas, sempre visíveis
• Picture-in-picture da lente secundária — por exemplo, a câmera de pacotes de uma campainha
• Perfis de layout para visibilidade, tamanho e ordem das câmeras
• Janela redimensionável, reordene as câmeras arrastando
• Atalho de teclado global para mostrar ou ocultar a janela
• Temas claro, escuro e automático com cores de destaque
• Sete idiomas
• Abrir ao fazer login

REQUISITOS
• Windows 10 versão 1809 (64 bits) ou posterior
• Um controlador UniFi Protect na sua rede local
• Uma chave da API de integração do seu controlador (para a lista de câmeras e as transmissões ao vivo)
• Uma conta de administrador local — opcional, necessária apenas para o controle PTZ

O QuickProtect é de código aberto sob a licença MIT. Comprá-lo aqui apoia o desenvolvimento e garante atualizações automáticas pela Microsoft Store.

O QuickProtect é um app independente e não é afiliado nem endossado pela Ubiquiti Inc. UniFi e UniFi Protect são marcas comerciais da Ubiquiti Inc.
```

**What's new in this version**
```
Primeira versão para Windows do QuickProtect, com os mesmos recursos do app para Mac: grade de câmeras ao vivo, visualização ampliada com tela cheia, controle PTZ, zoom digital, áudio, capturas, janelas fixadas, perfis de layout, atalho global e sete idiomas.
```

**Search terms**
```
UniFi | Protect | câmera de segurança | câmera IP | NVR | RTSP | PTZ
```

**Copyright and trademark info**
```
© 2026 CB Group LLC. UniFi e UniFi Protect são marcas da Ubiquiti Inc.
```
