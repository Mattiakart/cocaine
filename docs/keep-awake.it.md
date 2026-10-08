# Tenere sveglio il Mac: le funzioni in più

Cosa aggiunge Cocaine oltre all'interruttore e al timer (vedi anche [Alimentazione e trigger](power-and-triggers.it.md) e
[Script](scripting.it.md)). Tutto ciò che è nuovo resta spento finché non lo attivi, tranne "fino a un'ora", che agisce solo quando
premi Avvia.

## Fino a un'ora

- **Pannello**: Generale → *Tieni sveglio per* → *Fino a un'ora*: scegli l'ora (− / +, scorrimento, o l'elenco delle mezz'ore) e premi
  *Avvia*. Vale la prossima occorrenza: oggi, o domani se è già passata. La riga dice quanto manca.
- **Link**: `cocaine://on?until=18:30`, `on?until=08:00%20tomorrow`, `on?until=2026-10-07T18:30` (ora locale) o un orario ISO 8601
  completo di fuso (`2026-10-07T16:30:00Z`). Con x-callback-url la risposta contiene `until` e `remaining_minutes`.
- **Riga di comando**: `cocaine on until 18:30`, `cocaine on until 08:00 tomorrow`, `cocaine on until 2026-10-07T18:30`.
- **AppleScript**: `keep awake until "18:30"` o una data.
- Regole, uguali ovunque: nel futuro e **al massimo fra 24 ore** (altrimenti rifiutato, non cambia nulla); `until` mai insieme a
  `minutes`. Le ore sono lette sull'orologio tramite il calendario, quindi un cambio dell'ora legale in mezzo è contato giusto (nel
  giorno di 25 ore di ottobre "23:00" visto dalle 23:30 del giorno prima è fra 24,5 ore e viene rifiutato). Un'ora saltata dagli
  orologi (le 02:30 del giorno del salto di marzo) è letta come se non avessero saltato: 03:30. App e motore calcolano gli stessi
  istanti (provati attorno a mezzanotte e ai due cambi d'ora in Europe/Rome).
- `cocaine://on?timer=off` accende senza timer, qualunque sia la durata predefinita (lo usano i comandi rapidi per il Mac).

## Altri motivi di attivazione automatica (Automazioni → Attivazione automatica)

Ognuno, come gli altri, accende Cocaine finché vale e lo spegne dopo un margine, solo se l'ha acceso un trigger; se lo spegni tu, vince
la tua scelta finché il motivo non sparisce; *Ne vale almeno uno/Valgono tutti* li combina con gli altri.

| Trigger | Cosa legge | Permesso | Spento dopo |
|---|---|---|---|
| Una VPN è connessa | un'interfaccia tunnel (`utun`, `ipsec`, `ppp`, `tun`, `tap`, `wg` + numero) attiva con un indirizzo IPv4 o IPv6 instradabile (`getifaddrs`). Le utun di macOS (Relay privato di iCloud, Continuity) hanno solo indirizzi link-local e non contano | nessuno | 30 s |
| Processore occupato / a riposo | il carico della CPU (`host_statistics`, ogni 5 s) sopra (o sotto) 10/25/50/75 % senza interruzioni per 1/2/5/10 min | nessuno | 60 s |
| L'audio esce da | il nome dell'uscita audio predefinita (CoreAudio) contiene uno di quelli scelti (cuffie, AirPlay, un monitor) | nessuno | 30 s |
| Un disco è collegato | uno dei volumi scelti è montato | nessuno | 30 s |
| Un dispositivo USB è collegato | uno dei dispositivi USB scelti è collegato (nomi di prodotto da IOKit) | nessuno | 30 s |

La **rete Wi-Fi**, un **dispositivo Bluetooth** e molto altro sono condizioni dei [profili](awake-profiles.it.md) (Automazione →
Profili): la rete Wi-Fi richiede i Servizi di localizzazione (da macOS 14 è l'unico modo di leggerne il nome), il Bluetooth nessun
permesso.

## Tieni sveglio mentre… (Automazioni)

- **Un programma è aperto**: sceglilo dall'elenco dei tuoi processi in esecuzione (prima le app). Cocaine si accende senza timer e si
  spegne quando quel processo termina (controllato ogni 2 s). Il processo è riconosciuto dal pid *e* dall'ora di avvio, quindi un pid
  riusato da un altro programma non conta.
- **Ci sono download in corso**: Cocaine resta acceso finché nella cartella Download c'è un file parziale di un browser (`.crdownload`,
  `.download`, `.part`, `.partial`, `.opdownload`) o un file cresciuto dall'ultimo controllo, e si spegne un minuto dopo la fine
  dell'ultimo. Serve il permesso File e cartelle per Download (se negato, la riga lo dice e non parte nulla).
- *Interrompi* smette di aspettare e lascia Cocaine com'è; spegnere Cocaine a mano termina anche l'attesa. Ciò che si aspetta resta
  dopo un riavvio dell'app (un aggiornamento) solo se Cocaine è ancora acceso. Se l'app va in crash, il suo lease di ripristino rimette
  lo stop come al solito ([Ripristino](recovery.it.md)): non resta nulla a tenere sveglio il Mac.
- Il comando `cocaine watch` non è questo: è il watchdog dell'app.

## Opzioni (Generale → Tenere sveglio)

- **Spegni se scolleghi l'alimentatore**: Mai / Subito (10 s, così un cavo che balla non conta) / 5 min / 15 min dopo aver scollegato
  l'alimentatore, comunque sia stato acceso Cocaine. Solo a uno scollegamento vero: un Mac già a batteria quando Cocaine si apre non è
  toccato, e riaccendere Cocaine mentre sei a batteria è rispettato. Protezione batteria e la soglia del 5 % funzionano come prima.
- **Pausa mentre lo schermo è bloccato** (`com.apple.screenIsLocked`/`Unlocked`, nessun permesso): al blocco Cocaine lascia dormire il
  Mac e nessun trigger lo accende; allo sblocco un'accensione fatta a mano torna con il tempo che restava al timer (non se nel frattempo
  è scaduto); un'accensione fatta da un trigger torna da sola se il trigger vale ancora. Un cambio da fuori mentre è bloccato
  (l'iPhone, `cocaine on`) vince. Non usarla per lavorare a coperchio chiuso: chiuderlo blocca lo schermo.
- **Accendi all'apertura di Cocaine**: Sempre (come prima), Non al login (solo quando lo apri tu; l'avvio come elemento di login si
  riconosce dall'evento di avvio), Mai. Un link che avvia l'app decide comunque da sé. *Non verificato su questo Mac*: che macOS 14–27
  segni allo stesso modo l'avvio come elemento di login di un'app `SMAppService` (`keyAELaunchedAsLogInItem`); se non lo fa, "Non al
  login" si comporta come "Sempre".
- **Il clic sinistro lo accende o spegne**: con l'icona nella barra dei menu (isola disattivata), un clic sinistro alterna e un clic
  destro o ⌃-clic apre il pannello. VoiceOver annuncia il nuovo stato.
- **Icona nella barra dei menu**: Bustina (predefinita), Tazza, Fulmine, Occhio o Punto: vuota da spento, piena da acceso (SF Symbols,
  template). L'isola mantiene la bustina.
- **Avvisi quando si accende o spegne**: un breve avviso nell'isola (o un annuncio di VoiceOver quando l'isola non è visibile) a ogni
  cambio, con il trigger che l'ha causato. Spento in partenza. Cocaine non usa le notifiche di macOS (servirebbe un altro permesso).
