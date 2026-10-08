# Predefiniti e funzioni di base di macOS

Regola (2.9): Cocaine non cambia il funzionamento delle cose di base del Mac (copia e incolla, Handoff / Appunti universali,
AirDrop, tasti volume e luminosità, Bluetooth, Wi-Fi, Spazi, abbreviazioni da tastiera, Dock e barra dei menu, Full immersion,
istantanee dello schermo) se non hai attivato tu quella funzione. L'unica eccezione è lo scopo di Cocaine: tenere il Mac acceso
mentre Cocaine è attivo.

`--basics-test` controlla questa tabella sul codice, con impostazioni solo in memoria (Sources/Basics.swift, Sources/BasicsTests.swift).

## Cambiato nella 2.9

| Cosa | Prima | Ora | Impostazioni di prima della 2.9 |
|---|---|---|---|
| **Appunti universali** (copi su iPhone/iPad/un altro Mac, incolli qui, e viceversa) | Ogni copia da un altro dispositivo veniva letta subito, con tutti i formati (formattazione, HTML, immagini, file, indicatore d'origine): ognuno un trasferimento da quel dispositivo, mentre il sistema la stava ancora portando | Lasciata stare: non viene letta affatto. Con *Copie da altri dispositivi* attivo: solo il testo semplice, 3 s dopo l'arrivo, mai immagini o file | Spento una volta (era il vecchio predefinito; se lo riattivi resta attivo) |
| **⌃⌘V** (apre gli appunti da qualsiasi app) | Registrato globalmente di default, così Word, Excel e PowerPoint perdevano Incolla speciale | Nessuna combinazione finché non ne registri una (⌃⌘V è suggerito nell'impostazione) | ⌃⌘V liberato una volta; una combinazione tua resta |
| **Link condivisi** negli appunti | Marcati *nascosti* (altre app e il sistema possono tenere una copia così solo su questo Mac) | Una copia normale; solo la cronologia di Cocaine la salta | — |

## Cosa fa Cocaine con le impostazioni iniziali

| Area | Predefinito | Tipo | Quando | Come spegnerlo |
|---|---|---|---|---|
| Stop (pmset `disablesleep`, `caffeinate -d`) | Cocaine si attiva all'avvio | la funzione stessa | mentre Cocaine è attivo; ripristinato all'uscita, a un crash o alla disinstallazione (watchdog) | *Accendi all'apertura di Cocaine* → Mai, o spegni Cocaine |
| Password amministratore (regola sudo solo per `pmset -a disablesleep 1/0`) | chiesta la prima volta che Cocaine si attiva | la funzione stessa | una volta | `Cocaine.app/Contents/MacOS/Cocaine --remove-rule` |
| Oscuramento a riposo / regola del coperchio (luminosità o gamma) | attivo | la funzione stessa | solo con Cocaine attivo e tu inattivo / coperchio chiuso; ripristinato al primo input o allo spegnimento | *Quando sei inattivo* |
| Tasti volume / luminosità e l'indicatore di sistema | quelli di macOS | su richiesta | solo con *Sostituisci l’HUD di sistema* (chiede Accessibilità) | — |
| Retroilluminazione tastiera | mai toccata | su richiesta | solo con Retroilluminazione tastiera → *Spegni quando inattivo* | — |
| Input sintetico (Resta disponibile) | spento | su richiesta | solo con *Resta disponibile* | — |
| Attivazioni smart, VPN, orari, risveglio per il telefono | spenti | su richiesta | — | — |
| Link `cocaine://` che cambiano lo stop | chiedono prima | su richiesta | — | — |
| Abbreviazioni globali ⌃⌥⌘C / ⌃⌥⌘O / ⌃⌥⌘P / ⌃⌥⌘I | attive | di Cocaine (nessuna abbreviazione di macOS le usa; controllate con Impostazioni di Sistema) | sempre | la scheda *Scorciatoie da tastiera* (una per una, o tutte) |
| Combinazione degli appunti (apri), Pila Incolla (⌃⌥⌘V) | nessuna / solo mentre una pila aspetta | su richiesta | — | Isola → Appunti |
| Cronologia appunti | in memoria, legge le copie di questo Mac | passiva (legge; scrive solo quando clicchi un elemento) | con l'isola attiva | Isola → Appunti → Pausa, o isola spenta |
| Copie degli Appunti universali | non lette | su richiesta | — | *Copie da altri dispositivi* |
| L'isola sopra il notch, gli swipe del trackpad lì | attiva | interfaccia di Cocaine (gli swipe sono ascoltati, mai bloccati) | con l'isola attiva | Impostazioni → Isola |
| Download e cartella istantanee (File dell'isola) | lette | passiva (può mostrare la richiesta di accesso alla cartella di macOS) | con l'isola attiva | Impostazioni → Isola |
| Musica / Spotify | letti solo se già aperti | passiva (chiede Automazione la prima volta) | con l'isola attiva | — |
| Elenco dispositivi Bluetooth (`system_profiler`) | solo nella pagina Stato o per un profilo che usa il Bluetooth | passiva | quando mostrato / serve | — |
| Nome Wi-Fi, Localizzazione | solo per un profilo che usa il Wi-Fi | su richiesta | — | — |
| Fotocamera | solo nella pagina Specchio | su richiesta | — | — |
| Microfono | mai aperto (solo se un'altra app ne usa uno) | passiva | — | — |
| Controllo aggiornamenti | una volta al giorno | rete | — | *Cerca aggiornamenti automaticamente* |
| Menu Servizi *Aggiungi allo scaffale di Cocaine* | elencato | passiva | — | Impostazioni di Sistema → Tastiera → Abbreviazioni → Servizi |
| Tipi di file, schemi URL | nessuno rivendicato (`LSHandlerRank None`), solo `cocaine://` | — | — | — |
| Elemento di login, icona nel Dock, impostazioni di altre app, Full immersion, suoni, salvaschermo | non toccati | — | — | — |

## Se il copia e incolla con Handoff non funziona

1. Esci da Cocaine (menu → Esci). Sull'iPhone copia una parola, sul Mac premi ⌘V in TextEdit entro un minuto. Poi al contrario.
2. Riapri Cocaine e ripeti. Con la 2.9 e *Copie da altri dispositivi* spento, Cocaine non tocca affatto queste copie.
3. Se non funziona nemmeno senza Cocaine: stesso Account Apple sui due, Bluetooth e Wi-Fi attivi, Impostazioni di Sistema →
   Generali → AirDrop e Handoff → *Consenti Handoff tra questo Mac e i dispositivi iCloud*, e sull'iPhone Impostazioni →
   Generali → AirPlay e Continuità → Handoff.
