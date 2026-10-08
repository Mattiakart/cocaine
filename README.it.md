<p align="center"><img src="docs/icona.png" width="128" alt="Icona di Cocaine"></p>

<h1 align="center">Cocaine</h1>

<p align="center"><b>Tiene sveglio il Mac, anche col coperchio chiuso.</b><br>
Una piccola app gratuita e open source per la barra dei menu di macOS.</p>

<p align="center"><img src="docs/demo.gif" width="360" alt="La bustina nella barra dei menu si riempie quando Cocaine si attiva"></p>

🇬🇧 [Read in English](README.md)

- **Bustina piena = attivo.** Il Mac non va in stop, nemmeno col coperchio chiuso. Funziona anche su Apple Silicon,
  senza componenti aggiuntivi da installare.
- **Bustina vuota = spento.** Il Mac si comporta normalmente.
- **Un interruttore.** Quello in alto nel pannello attiva o spegne Cocaine; mentre si accende ci scende dentro una
  sottile striscia di polvere.
- **Parla la tua lingua:** italiano, inglese, cinese (semplificato e tradizionale), spagnolo, francese, tedesco e giapponese.
  Segue la lingua del Mac (altrimenti l'inglese), oppure la scegli dalla bandiera nel pannello.
- **Luminosità.** Mentre è attivo, può abbassare tutti gli schermi al livello che scegli dopo qualche minuto di
  inattività. Lo schermo non si spegne mai del tutto, e torna com'era appena tocchi tastiera o trackpad.
- **Coperchio chiuso.** Con Cocaine attivo, chiudendo il coperchio lo schermo integrato va subito alla luminosità minima
  (qualunque sia l'impostazione di inattività) e riaprendolo torna al livello che aveva. I monitor esterni non vengono mai toccati
  dal coperchio: in modalità clamshell restano come sono e si abbassano solo per inattività, come sempre. I monitor Apple
  abbassano la retroilluminazione, gli altri si scuriscono via software. Il pannello si apre sotto l'icona che clicchi, su
  qualunque schermo.

<p align="center"><img src="docs/pannello.png" width="340" alt="Il pannello di Cocaine"></p>

Richiede macOS 14 (Sonoma) o successivo. Funziona su Mac Apple Silicon e Intel, pesa circa 600 KB, è gratis.

## Installazione

**Con Homebrew (il modo più semplice):**

```
brew install --cask mattiakart/tap/cocaine
```

Homebrew ti chiede la password del Mac **una volta**, direttamente nel Terminale, per dare il permesso a Cocaine. Se hai attivato
Touch ID per sudo, basta l'impronta. Nient'altro: nessuna finestra, niente "Apri comunque".
`brew upgrade` non chiede mai nulla, e `brew uninstall --cask cocaine` toglie tutto senza chiedere.

**Oppure scarica il .dmg** dalla pagina [Releases](../../releases/latest):

1. Apri il `.dmg` e trascina **Cocaine** in **Applicazioni**.
2. Aprila. macOS la blocca, perché l'app non è firmata da uno sviluppatore registrato presso Apple:
   vai in **Impostazioni di Sistema → Privacy e sicurezza** e clicca **"Apri comunque"**. Serve solo la prima volta.
3. Cocaine chiede **una volta** la password. macOS la mostra con un avviso perché l'app non è verificata da Apple: è normale.

In entrambi i casi quell'autorizzazione installa una regola sudo che permette solo `pmset -a disablesleep 1`,
`pmset -a disablesleep 0`, `pmset schedule wake`/`schedule cancel wake` marcati `cocaine` (usati solo da *Sveglia per iPhone*) e la
cancellazione della regola stessa. Nient'altro.

**Firma.** Le versioni attuali sono firmate con un certificato autofirmato di Cocaine (livello "locale"): gratuito, ma non
verificato da Apple e non notarizzato, da qui "Apri comunque". Il pannello mostra il livello della tua copia in *Permessi*. macOS
conserva i permessi concessi negli aggiornamenti firmati con lo stesso certificato, ma Apple non promette nulla per i
certificati autofirmati: se dopo un aggiornamento un interruttore risulta spento, riaccendilo una volta. La firma Developer ID e
la notarizzazione sono previste dagli script di build ma non ancora usate dalle versioni pubblicate. Gli **aggiornamenti
nell'app** (pannello → Aggiornamenti) verificano un manifest firmato Ed25519, l'hash del DMG e la firma della nuova app prima di
una sostituzione atomica, ma restano inattivi finché una versione non include un manifest firmato e la sua chiave pubblica non è
incorporata nell'app: fino ad allora usa `brew upgrade --cask cocaine` o il DMG. Le installazioni Homebrew non vengono mai
sostituite dall'app. Dettagli: [Firma e aggiornamenti](docs/signing-and-updates.it.md).

**Ricerca nelle impostazioni**: ⌘F (o scrivi e basta) nel pannello trova qualsiasi impostazione con parole tue, in ogni lingua
dell'app, anche con errori di battitura, e ti ci porta: [Ricerca nelle impostazioni](docs/settings-search.it.md).

**Movimento**: isola, HUD, pannello, dialoghi e menu a tendina si muovono con un unico insieme di molle e tempi, fluidi anche
quando un'interazione viene interrotta o ripetuta in fretta, e rispettano Riduci movimento (solo dissolvenze). Dettagli:
[Movimento](docs/motion.it.md).
**Notch**: le molle di Boring Notch per aprire e chiudere, un HUD della batteria quando colleghi o scolleghi il caricatore,
gesti a due dita (su chiude, giù apre, di lato cambia schermo), misure, un modulo Controlli e i Promemoria:
[Il notch](docs/notch-animations.it.md).

## Avvisi quando un'AI finisce

Lasci il Mac a lavorare, e Cocaine ti richiama quando un'AI finisce o ha bisogno di te. Se non sei al Mac riaccende gli
schermi, riporta la luminosità, li fa lampeggiare e mostra chi ti cerca e in quale progetto. Se sei al Mac, la bustina
nella barra si ricarica e basta.

La scheda **Avvisi AI** del pannello compare quando Cocaine trova sul Mac uno strumento AI supportato. In alto, **Agent** elenca le
sessioni al lavoro (oppure, se non ce n'è, gli **Ultimi avvisi**: i tre più recenti, con il progetto da cui arrivano). Poi tre
schede: **Ambienti rilevati** (ogni strumento, app e chat web AI trovato sul Mac, un interruttore dove c'è, e sei piccoli simboli per ciò che Cocaine riesce a vedere), **Quando** (finisce, ha bisogno di te, anche quando sei
al Mac, una volta sola per sessione quando non resta niente in corso, **Rispondi dall’isola**, spento di default, e **Pausa**: 30
minuti, un'ora o fino a domani) e **Come** (lampeggio, suono, voce e quale, quanto resta l'avviso sullo schermo, promemoria ogni
2, 5 o 10 minuti mentre sei via, e una prova). Con VoiceOver ogni avviso viene anche letto.

**Ogni sessione, nel notch.** La pagina Home dell'isola e il pannello elencano tutte le tue sessioni AI (con scorrimento quando
sono tante; fino a 100), prima quelle che hanno bisogno di te. L'elenco viene salvato e ricompare dopo un riavvio (con ↺ e l'età);
una sessione il cui processo è terminato viene tolta. **Clicca una sessione o un avviso** per tornare dove gira: la scheda esatta
di Terminale o iTerm2 (serve il permesso *Automazione* per quell'app, chiesto la prima volta), il pannello tmux, Zellij o
WezTerm, il terminale di Ghostty (1.3+), la finestra di kitty (con il suo controllo remoto attivo), la superficie di cmux, o la
finestra di VS Code, Cursor o Windsurf con la sua cartella; le tue **regole di salto** (un piccolo file JSON) coprono altre app.
Se non riesce ad arrivare fin lì porta avanti l'app o apre la cartella, e dice sempre cosa ha fatto. Il terminale integrato di un
IDE, JetBrains e Warp si possono solo portare in primo piano come app, e le sessioni avviate prima di questa versione non dicono
dove girano.

**Rivedi e rispondi dall’isola** (spento di default; Claude Code 2.0.45+ e Codex): i **piani** di Claude Code (modalità piano) in
Markdown con **Approva** o **Feedback** che Claude legge per rivederli; le sue **domande** (AskUserQuestion) con le opzioni, ⌘1–9 e
una risposta tua; le richieste di permesso con l'input **intero** (una modifica come diff colorato), **Consenti**, **Consenti
sempre** (la regola che Claude Code stesso propone), **Nega** con un motivo facoltativo e **Nel terminale**. ⌘Y / ⌘N funzionano
quando l'isola ha la tastiera (⌃⌥⌘I), mai globalmente. Usa solo gli hook documentati degli strumenti (`PreToolUse`,
`PermissionRequest`, `Elicitation`) su un socket privato, con risposte firmate e legate a una sola richiesta. Niente viene mai
approvato da solo: nessuna risposta entro 2 minuti, Cocaine non in esecuzione o qualsiasi errore, e lo strumento chiede nel
terminale come sempre. Gli altri strumenti della tabella avvisano soltanto. Dettagli: [Revisione dei piani](docs/ai-plans.it.md),
[Sessioni AI](docs/ai-sessions.it.md).

**Host SSH** (Impostazioni → AI): gli agenti che girano sui tuoi server compaiono allo stesso modo — avvisi, sessioni, piani,
domande e approvazioni nel notch — attraverso il tuo `ssh` (chiavi degli host verificate, nessun inoltro, nessuna porta aperta) e un
piccolo relay in perl che Cocaine installa là solo dopo il tuo OK, mostrandoti prima ogni modifica alle impostazioni degli
strumenti. Dettagli: [Host SSH](docs/ssh-hosts.it.md).

**Limiti del piano.** La pagina Stato dell'isola mostra i limiti di 5 ore e settimanali di Claude (Pro/Max, dalla statusline di
Claude Code stesso, quando attivi *Limiti del piano Claude*; la tua statusline continua a funzionare) e le finestre di Codex,
chiamate con la loro durata reale, con il tempo a ogni azzeramento. Niente password, Portachiavi o rete:
[Limiti del piano](docs/ai-quotas.it.md).

**Oltre gli hook.** I file di sessione di Claude Code e le CLI avviate in un terminale mostrano le sessioni aperte (anche senza
hook), le sessioni finiscono quando il loro processo termina o la loro app si chiude (niente più righe ferme su "al lavoro"), e la
stessa sessione vista in più modi è una sola riga. Un thread Codex dell'app ChatGPT si apre con il suo link `codex://threads/<id>`.
**Chat sul web** (spento di default) elenca le schede dei siti di chat aperte in Safari o in un browser Chromium e torna alla
scheda; vede solo gli indirizzi, mai le risposte. Le chat di Claude Desktop, Cowork e le altre app senza hook si vedono solo aperte
o chiuse. Cosa funziona dove, con le prove e ciò che resta limitato: [Integrazioni AI](docs/ai-integrations.it.md).

| AI | Finisce | Ha bisogno di te | Dove va l'hook di Cocaine |
|---|---|---|---|
| Claude Code (CLI, IDE, scheda Code di Claude Desktop) | ✓ | ✓ permesso o domanda | `~/.claude/settings.json` |
| Codex (CLI, app ChatGPT, estensione IDE) | ✓ | ✓ approvazione | `~/.codex/hooks.json` |
| Cursor | ✓ | – | `~/.cursor/hooks.json` |
| GitHub Copilot (CLI e VS Code) | ✓ | ✓ nella CLI | `~/.copilot/hooks/cocaine.json` |
| Gemini CLI | ✓ | ✓ permesso | `~/.gemini/settings.json` |
| Windsurf | ✓ dopo ogni risposta | – | `~/.codeium/windsurf/hooks.json` |
| Qwen Code | ✓ | ✓ permesso | `~/.qwen/settings.json` |
| OpenCode | ✓ | ✓ permesso o domanda | `~/.config/opencode/plugins/cocaine.js` |

Cocaine aggiunge solo i suoi hook e lascia com'è tutto il resto di quei file. Togliendo la spunta a un'AI li rimuove, e
lo fa anche `brew uninstall`. Codex esegue un hook nuovo solo dopo che l'hai approvato una volta (te lo chiede all'avvio
nel Terminale, oppure nell'app ChatGPT vai in Impostazioni → Hooks): finché non lo fai, il pannello te lo ricorda.
Cursor esegue anche gli hook di Claude Code, quindi quello di Cocaine per Claude Code dentro Cursor tace: niente avvisi
doppi.

**Qualsiasi altro programma** può suonare il "campanello":

```
open -g "cocaine://alert?from=Il%20mio%20script&event=done"     # event=done o input; project=nome; oppure message=testo
```

- **Altre AI** con hook o plugin che possono eseguire quel comando: Aider (`notifications-command` in
  `~/.aider.conf.yml`), Cline (`~/Documents/Cline/Hooks/TaskComplete`), Factory Droid (`~/.factory/hooks.json`), Kiro,
  Amp, Goose, JetBrains Junie (non sull'hook `PermissionRequest`: se esce senza decidere, Junie approva l'azione).
- **Build e terminali:** Xcode (Impostazioni → Behaviors → Run script), qualsiasi comando lungo (`make; open -g …`),
  `notify_on_cmd_finish` di kitty, i Trigger di iTerm2, `alert-silence` di tmux.
- **CI e git:** `gh run watch --exit-status; open -g …`, hook di git come `post-merge`.
- **App di automazione:** Comandi Rapidi ("Apri URL"), Keyboard Maestro, Hammerspoon, BetterTouchTool, `WatchPaths` di
  launchd, regole di Mail.

Gli hook di avviso di Cocaine iniziano con `pgrep -qx Cocaine`: l'avviso parte solo se Cocaine è aperto, e non lo riapre se l'hai
chiuso. L'hook di Consenti/Nega esegue invece il programma di Cocaine stesso, che non dà risposta (chiede il terminale) se l'app
non è aperta.

## Feedback e assistenza

**Feedback o assistenza → Scrivi…**, nella scheda Cocaine del pannello (Generale), apre una mail all'autore con le versioni di Cocaine e di macOS già scritte.
Bug e idee sono benvenuti anche come [issue su GitHub](https://github.com/Mattiakart/cocaine/issues).

## Isola

Cocaine vive anche nel notch (o, su uno schermo senza, in una sottile barra in alto; l'interruttore allora si chiama *Mostra in cima
allo schermo*). Chiusa, la busta sta a sinistra del notch e a destra la cosa attiva più importante, una alla volta: un breve
messaggio (il nome del file appena scaricato, "Screenshot", "Copiato", le barre di volume e luminosità), il conto alla rovescia del
focus, un'AI che aspetta te, il microfono in uso, le AI al lavoro (✦ e quante), il brano in riproduzione, Cocaine acceso e fino a
quando, oppure *Resta disponibile*. Ci passi sopra o ci clicchi e si apre subito (e si chiude appena il puntatore esce), con queste
pagine:

- **Home**: l'interruttore, il timer, *Resta disponibile*, gli agent AI al lavoro.
- **Musica**: Musica e Spotify, con copertina, barra di avanzamento, play/pausa/avanti/indietro/casuale e, se li attivi, i
  testi sincronizzati (cercati per titolo e artista su lrclib.net, non si invia altro; un problema di rete viene detto come tale).
  Cosa suona arriva dagli annunci delle app stesse; il loro scripting (permesso Automazione) serve per la copertina e, mentre questa
  pagina è aperta, per la posizione. Anche **YouTube Music tramite Pear Desktop** (il suo plugin API Server, solo su questo Mac,
  dopo che lo colleghi), un selettore quando più lettori hanno un brano, salto indietro/avanti (5–30 s), preferito/Mi piace dove
  il lettore lo consente e il volume del lettore. La **retroilluminazione della tastiera** (MacBook) ha un modulo, un HUD e uno
  spegnimento facoltativo quando sei inattivo. Vedi [docs/music-and-backlight.it.md](docs/music-and-backlight.it.md).
- **Calendario**: viste Giorno, Settimana e Mese con precedente/successivo, *Oggi* e i tasti freccia; clic su un evento per i
  dettagli (orario, calendario, luogo, link della videochiamata, partecipanti, note) e *Apri in Calendario*. Chiede l'accesso a
  Calendario la prima volta; se l'hai negato, un pulsante apre Impostazioni di Sistema. Vedi [docs/calendar.it.md](docs/calendar.it.md).
- **Focus**: un timer focus/pausa con righello dei minuti; avviare un focus tiene il Mac sveglio per la sua durata, *Azzera* spegne
  Cocaine solo se l'aveva acceso il focus, la fine viene annunciata (un suono, un lampo, un avviso se non sei al Mac) e un focus in
  corso sopravvive a un riavvio o a un aggiornamento.
- **Le tue schermate**: Impostazioni → Isola → *Schermate* mostra o nasconde ogni pagina, le riordina (trascinando, o con le
  frecce), sceglie quella su cui si apre l'isola e mette moduli di pagine diverse nella stessa schermata (due colonne, ogni modulo
  S, M o L) con anteprima dal vivo e *Ripristina predefinite*. Vedi [docs/screens.it.md](docs/screens.it.md).
- **Scaffale**: trascina file, immagini, link o testo sull'isola (si apre da sola) in raccolte con nome; selezionane più d'uno, Quick Look, trascinali fuori insieme, rinomina in gruppo, ZIP, ridimensiona/converti immagini, riconosci il testo, esegui azioni tue, e lascia che le cartelle osservate (Istantanee, Download…) lo riempiano. Anche dal menu Servizi, con `open -a Cocaine` e `cocaine shelf add`. [Dettagli e limiti](docs/shelf.it.md).
- **Link cloud**: carica i file dello scaffale nel tuo bucket S3/R2/B2/Wasabi/Spaces/MinIO, su Nextcloud, in una cartella WebDAV, sul tuo server via SFTP (solo chiavi) o con un tuo comando, e ottieni un link (con scadenza, revocabile, escluso dalle cronologie degli appunti); segreti nel Portachiavi, nulla caricato senza un clic. Le azioni dello scaffale possono anche essere webhook, avere i tasti ⌥1–⌥9, eseguirsi una dopo l'altra ed essere importate/esportate. [Dettagli e limiti](docs/cloud-sharing.it.md).
  Tiene dei riferimenti, non copie, e resta dopo un riavvio (i file spariti nel frattempo vengono tolti).
- **File**: download e screenshot recenti, da trascinare fuori (in qualsiasi app, Mail, AirDrop…); un lampo col nome del file avvisa
  quando ne arriva uno. Le due cartelle vengono osservate, non rilette ogni pochi secondi.
- **Appunti**: ciò che hai copiato da poco (testo con la sua formattazione, immagini, riferimenti a file), con ricerca e filtri;
  doppio clic o A capo incollano nell'app che stavi usando (con il permesso Accessibilità; altrimenti copiano), ⌘1–9 incolla
  rapido, selezione multipla, Pila Incolla, unione, modifica, rinomina, anteprime, testo nelle immagini, suggerimenti per l'app in
  primo piano, copie da altri dispositivi riconosciute, e `cocaine clip` (spento di default). **Bacheche** (raccolte con nome) e
  **snippet** con segnaposto sono sempre salvati, cifrati; il resto solo in memoria, a meno che attivi *Salva su questo Mac*
  (cifrato, con limiti di conservazione, esclusioni e *Elimina tutto*); mai dai gestori di password.
  [Dettagli e limiti](docs/clipboard.it.md), [bacheche](docs/pinboards.it.md). **Dalla tastiera**: una combinazione che registri (nessuna di default) li apre da qualsiasi app
  (nell'isola, o in un pannello mobile vicino al puntatore), scrivi per cercare (parole, approssimata, regex), A capo incolla
  nell'app in cui eri, ⇧A capo senza formattazione. [Tasti](docs/clipboard-keyboard.it.md).
- **Contesto AI (MCP)** (disattivo di serie): metti nel *contesto AI* elementi degli appunti, file dello scaffale e note, e lascia
  che Claude Code, Claude Desktop, Codex, Cursor o Gemini CLI leggano **solo quelli**, dopo che hai consentito ogni strumento nella
  notch; un clic collega uno strumento (mostrato prima, reversibile), un registro annota ogni lettura senza il contenuto. Un server
  MCP stdio locale, nessuna porta di rete. [Dettagli, strumenti, consenso e limiti](docs/mcp.it.md).
  [Dettagli e limiti](docs/clipboard.it.md), [bacheche](docs/pinboards.it.md). **Sincronizzazione appunti con iPhone** (spenta di
  default): elementi da e verso l'iPhone tramite una cartella in iCloud Drive e due Comandi Rapidi creati da Cocaine (*Invia al
  Mac*, *Ricevi dal Mac*; testo e immagini), e testo breve tramite l'iPhone abbinato, cifrato end-to-end; nessuna app per iPhone,
  nessun account. [Come funziona e i suoi limiti](docs/clipboard-sync.it.md).
- **Stato**: le batterie del Mac, degli AirPods e di altri dispositivi Bluetooth (aggiornate al massimo una volta al minuto), e
  l'utilizzo di Codex (i limiti, dalle sessioni più recenti che li riportano) e Claude Code (i token delle ultime 5 ore e 7 giorni),
  letti dai loro file locali. I file di Claude Code vengono letti una volta, poi solo la parte aggiunta; un primo conteggio su una
  cronologia grande dice *Conteggio in corso* finché non è completo.
- **Multimedia**: Apple Music, Spotify, YouTube Music, Netflix, Prime Video, YouTube, Disney+, Apple TV, Twitch, DAZN: un tocco apre l'app se
  è installata, altrimenti il sito nel browser predefinito.
- **Specchio**: la fotocamera dal vivo, accesa solo mentre quella pagina è aperta; un interruttore la specchia (o ti mostra come ti vedono gli
  altri) e puoi scegliere la fotocamera.
- **Monitor** (solo con un monitor esterno): luminosità, contrasto, volume e ingresso del monitor stesso via DDC/CI, solo Apple
  silicon (su Intel la scheda non compare); non tutti i monitor lo supportano. I valori attuali vengono letti dal monitor quando
  risponde (altrimenti compare –), e un monitor che non accetta una modifica lo segnala.

Anche il caricatore collegato o scollegato viene annunciato. L'isola sostituisce l'icona nella barra dei menu: la busta di Cocaine, sempre a sinistra, si riempie e si svuota come faceva l'icona (polvere
bianca: Cocaine è attivo; polvere rosa: Cocaine è spento ma *Resta disponibile* è acceso, con o senza app di chat aperte). Se disattivi l'isola, l'icona torna. Si apre e si chiude
seguendo le linee del notch, con un leggero tocco sul trackpad dove serve (timer, interruttori, pagine; Generale → *Feedback aptico* lo disattiva; con Riduci
movimento attivo nelle impostazioni Accessibilità di macOS compare e scompare senza animazione, e gli avvisi tingono lo schermo una volta invece di
lampeggiare). L'ingranaggio apre il pannello delle impostazioni; Generale → *Mostra nel notch* la disattiva. Si nasconde durante video a schermo intero e
giochi sul suo schermo (una finestra grande su un altro monitor non conta). C'è un'isola su ogni schermo collegato: il notch dove
c'è, una barra sottile sugli altri; ognuna si apre da sola quando il puntatore la tocca, e un'app a schermo intero nasconde solo
l'isola del suo schermo (Isola → *Mostra su tutti gli schermi* spento ne tiene una sola: lo schermo col notch, altrimenti quello
integrato, altrimenti il principale) ([dettagli](docs/island-screens.it.md)). Con Isola → *Sostituisci l'HUD di sistema* attivo,
Cocaine gestisce da sé i tasti di volume e luminosità (passi fini con ⌥⇧; ⌥ da solo apre ancora le impostazioni Suono o Monitor) e
la loro barra compare subito sotto il notch, larga quanto il notch, invece di quella di macOS; lì compaiono anche messaggi come
*Scaricato* o *Copiato*. Serve il permesso **Accessibilità**, che chiede quando attivi
l'opzione. Quando l'isola non si vede (un'app a schermo intero, il pannello delle impostazioni aperto, la sessione di un altro
utente) i tasti vanno a macOS e macOS mostra il suo indicatore. Prima di macOS 26 il processo di supporto del suo indicatore resta
anche congelato mentre l'isola mostra le barre, e torna quando disattivi l'opzione o chiudi Cocaine; se Cocaine va in crash o viene
terminato, un piccolo watchdog lo restituisce in un paio di secondi ([dettagli](docs/recovery.it.md)). Da macOS 26 l'indicatore lo
disegna Centro di Controllo, che Cocaine non tocca. Senza il permesso, macOS cambia comunque volume e luminosità e l'isola li mostra.

**Da tastiera e con VoiceOver.** ⌃⌥⌘I (Generale → *Scorciatoie da tastiera*, modificabile) apre l'isola con la tastiera dentro:
resta aperta finché premi Esc, di nuovo la scorciatoia o clicchi altrove; ← e → cambiano scheda, Tab passa tra i controlli (con
Accesso completo da tastiera) e nella pagina Appunti ↑, ↓ e A capo incollano un elemento. Per VoiceOver l'isola chiusa è un solo
elemento, "Cocaine", che dice cosa mostra e apre l'isola; mentre VoiceOver è attivo resta anche l'icona nella barra dei menu.
Vengono annunciati i lampi dell'isola, un'AI che inizia a lavorare, avvisi e richieste, e cosa hanno fatto una scorciatoia o un
link. Cocaine segue Aumenta contrasto, Differenzia senza colore e Riduci movimento (niente polvere che scende, niente molle,
visualizzatore fermo).


## Lavoro da remoto

Lasci il Mac e continui a lavorare dal telefono. Cocaine tiene sveglio il Mac (il coperchio può restare chiuso) e un
piccolo comando ti permette di avviare, seguire e guidare gli agent AI da qualsiasi posto in cui puoi eseguire un comando.

**Da fare una volta, da qualsiasi parte del mondo, senza password e senza altre app.** Cocaine non apre nessuna porta di
rete e non richiede né il Login remoto né una VPN. L'app tiene una connessione in uscita verso un relay ([ntfy](https://ntfy.sh),
lo stesso servizio che possono usare gli avvisi sul telefono) e il Comando Rapido dell'iPhone parla con l'app attraverso di esso.

1. Nel pannello: *Lavoro da remoto → iPhone → Invia*. Scegli cosa può fare il telefono e Cocaine crea un Comando
   Rapido (un menu: Stato, Attiva, Spegni, Progetti, Comando, Ultima risposta), lo firma (servono internet e iCloud sul Mac)
   e apre la condivisione: lo mandi con AirDrop o con Messaggi.
2. Sull'iPhone lo aggiungi e lo esegui. Basta: il segreto che contiene il Mac lo conosce già.

*Comando* accetta qualsiasi comando `cocaine remote`, per esempio `start claude mio-progetto Correggi i test che falliscono`,
`log claude-mio-progetto 30`, `send claude-mio-progetto Sì, procedi` (gli ultimi tre richiedono il livello agent). Il Comando
Rapido aspetta qualche secondo e mostra la risposta; *Ultima risposta* la mostra di nuovo.

Come è protetto: ogni iPhone abbinato riceve due nomi di canale casuali sul relay e una propria chiave casuale da 256 bit. Comandi
e risposte sono **autenticati e cifrati end-to-end** con essa, quindi il relay vede solo testo cifrato (non il comando, lo stato,
i nomi dei progetti o l'output degli agent); un comando senza la chiave giusta viene ignorato e una risposta è legata alla
richiesta a cui risponde. **I replay sono rifiutati per sempre**: ciò che il Mac ha eseguito viene salvato su disco prima
dell'esecuzione, quindi i duplicati consegnati di nuovo dopo una riconnessione, un risveglio o un riavvio vengono scartati, e i
comandi più vecchi di due minuti (20 con *Sveglia per iPhone*) o datati nel futuro sono rifiutati. *Revoca* dimentica subito tutti
gli iPhone abbinati (un comando già in corso non riceve risposta); un abbinamento scade dopo 180 giorni. Ogni comando passa da
una lista fissa di comandi permessi: il livello di base permette stato, attiva/spegni ed elenco dei progetti; *Anche avviare e
guidare gli agenti AI* aggiunge l'avvio degli agent e la possibilità di scrivere loro, il che equivale a eseguire codice come te:
concedilo consapevolmente. Al massimo 20 messaggi al minuto vengono esaminati (gli altri sono scartati senza leggerli) e ogni comando è registrato in
`~/Library/Application Support/Cocaine/remote-phone.log`. Trattalo come una chiave: il Comando Rapido contiene la chiave, si
sincronizza tramite iCloud come ogni Comando Rapido e chiunque lo ottenga può usarlo.

**I Comandi Rapidi creati prima di questa versione** (testo in chiaro, non autenticati) vengono rifiutati dopo l'aggiornamento; il
pannello mostra una riga arancione *Comandi Rapidi vecchi*: manda un nuovo Comando Rapido e poi *Rimuovi*, oppure *Consenti 14
giorni* per far eseguire intanto quelli vecchi solo i comandi di base (mai avviare agent), senza protezione.

Limiti, onestamente: l'app Comandi Rapidi non ha un'azione di cifratura, quindi il Comando Rapido la fa con hash ed espressioni
regolari (costruzioni standard, verificate col codice del Mac). È grande (circa 650 azioni), un comando richiede qualche secondo
sull'iPhone e le risposte oltre circa 2.800 byte vengono tagliate. Il relay vede ancora quando e quanto spesso mandi comandi e può
ritardarli o scartarli. Un comando su cui il Mac va in crash subito dopo averlo accettato non viene eseguito (mai due volte).
**Il nuovo Comando Rapido è stato verificato in un simulatore delle sue azioni, non ancora su un iPhone reale.** Il Mac deve essere
sveglio per rispondere: a questo serve Cocaine acceso. Per evitare un relay di terzi usa un tuo server ntfy:
`defaults write local.cocaine.toggle relayURL https://ntfy.esempio.it` (solo https), poi abbina di nuovo. Descrizione completa:
[Sicurezza del controllo remoto](docs/remote-security.it.md).

Gli stessi comandi funzionano in Terminale:

```
C=/Applications/Cocaine.app/Contents/Resources/cocaine
$C remote status                       # Cocaine, batteria, agent al lavoro
$C remote on --for 3h                  # Mac sveglio per 3 ore
$C remote projects                     # le cartelle in cui puoi lavorare
$C remote start claude mio-progetto Correggi i test che falliscono
$C remote start codex mio-progetto --resume
$C remote log claude-mio-progetto 30    # cosa mostra l'agent sullo schermo
$C remote send claude-mio-progetto Sì, procedi
$C remote key claude-mio-progetto enter # anche esc, up, down, tab, ctrl-c, y, n, 1-9
$C remote stop claude-mio-progetto
```

Agent: Claude Code, Codex, Gemini CLI, Cursor, GitHub Copilot, OpenCode, Qwen Code e Aider (`remote agents` elenca quelli
installati; `--resume` riprende l'ultima conversazione per Claude Code, Codex, Cursor, Copilot e OpenCode). Ognuno gira
in una sessione `screen` che sopravvive alla chiusura della connessione (`remote attach <run>` la riprende in un
terminale). I progetti sono le cartelle con un `.git` sotto `~/Developer`, `~/Projects`, `~/Documents` e `~/Desktop`
(la lista si cambia in `~/Library/Application Support/Cocaine/projects.conf`). Cocaine si attiva quando parte il lavoro
e torna com'era quando finisce l'ultimo.

**Sapere cosa succede.** Gli hook degli Avvisi AI dicono a Cocaine anche quando un agent inizia a lavorare, aspetta te,
finisce o va in errore, e il pannello li elenca. `remote status` mostra lo stesso, e gli **Avvisi sul telefono** ti
mandano gli avvisi che arrivano mentre non sei al Mac: in *Lavoro da remoto → Avvisi sul telefono → Imposta…* (o con
`cocaine remote notify shortcut "Nome"`) Cocaine esegue sul Mac quel Comando Rapido con il testo dell'avviso come input
(costruiscine uno che ti manda un messaggio o una notifica), oppure (`notify ntfy https://ntfy.sh/il-tuo-argomento-segreto`) lo
pubblica su un argomento ntfy come notifica push (il testo esce dal Mac). *Prova* (o `cocaine remote notify test`) lo prova e la
riga dice com'è andata.

**Svegliare il Mac.** È Cocaine attivo a tenerlo raggiungibile. Un Mac già andato in stop non sente il relay, e niente da
internet può svegliare un MacBook in stop con il coperchio chiuso. Quindi, in *Lavoro da remoto*, attiva **Sveglia per
iPhone**: Cocaine programma un breve risveglio ogni 15 minuti (anche con il coperchio chiuso). A ogni risveglio si
ricollega, esegue i comandi che l'iPhone ha mandato nel frattempo (fino a 20 minuti di età), risponde e lascia che il Mac
torni a dormire. Quindi un comando mandato a un Mac in stop riceve risposta entro circa 15 minuti: lo mandi e dopo usi
*Ultima risposta*. Chiede il permesso una volta (estende la regola sudo di Cocaine con `pmset schedule wake`/`cancel wake`,
marcati `cocaine`, nient'altro), consuma un po' di batteria, si ferma a batteria al 20% o meno e viene annullata quando
chiudi Cocaine. Se serve la risposta subito, tieni Cocaine attivo. Si può attivare solo dopo aver abbinato un iPhone.
(`cocaine remote wake-info` stampa ancora quello che serve a un'app Wake-on-LAN, da usare sulla rete di casa.)

**Anche dai Comandi Rapidi e dagli script sul Mac.** Nelle versioni pubblicate Cocaine non ha azioni native per i Comandi Rapidi:
Comandi Rapidi le esegue solo per app firmate con un'identità rilasciata da Apple (un Team ID), e Cocaine è firmato in locale (il codice
è pronto dietro un'opzione di build: [docs/maintainers/app-intents.md](docs/maintainers/app-intents.md)). Al loro posto: un
**dizionario AppleScript** (`tell application "Cocaine" to keep awake for 90`, `keep awake until "18:30"`, `stop keeping awake`,
`toggle`, e da leggere `awake`, `awake until`, `remaining minutes`…), usabile da *Esegui AppleScript* di Comandi Rapidi; quattro
**comandi rapidi pronti per il Mac** (Tieni sveglio…, Spegni, Alterna, Stato che restituisce un Dizionario) che Automazioni → *Comandi
Rapidi e script* crea, firma e apre in Comandi Rapidi; i link (`cocaine://on?minutes=90`, `on?until=18:30`, `on?timer=off`, `off`,
`toggle`, `timer`, `status` con risposta x-callback; anche `pause`, `resume`, `panel`) e il comando incluso (`cocaine on 90m`,
`cocaine on until 18:30`, `off`, `status --json`). Ciò che cambia qualcosa funziona solo dopo il tuo consenso (una domanda la prima
volta, oppure Generale → *App Comandi Rapidi e link*), perché qualsiasi app, script o pagina web potrebbe chiederlo. Vedi
[Script](docs/scripting.it.md), [Tenere sveglio il Mac](docs/keep-awake.it.md) (fino a un'ora, altri trigger, sveglio finché gira un
programma o finiscono i download, spegnimento quando scolleghi l'alimentatore, pausa a schermo bloccato),
[Profili per tenere sveglio il Mac](docs/awake-profiles.it.md) (profili alla Amphetamine su Wi-Fi, rete, VPN, USB, Bluetooth, uscita
audio, CPU, app in primo piano, inattività, download…; dischi tenuti svegli; statistiche) e
[Alimentazione e trigger](docs/power-and-triggers.it.md).

### Automazioni

**Resta disponibile** (scheda Automazioni): Teams, Slack, Zoom e app simili ti segnano "Assente" in base all'inattività del Mac. Mentre
sei inattivo, con una delle app scelte aperta (o sempre), Cocaine invia un evento di mouse invisibile poco prima che ti segnino
assente (dopo circa 4 minuti e mezzo, o prima del salvaschermo se parte prima), che riavvia quell'orologio, e tiene lo schermo
acceso. Quindi, mentre è attivo, non partono nemmeno il salvaschermo, il blocco e lo spegnimento dello schermo. Serve il permesso
Accessibilità; verifica che nel tuo lavoro sia consentito.

Le schede del pannello stanno a sinistra e a destra del notch: *Generale* (**Tieni sveglio per**: ∞, da 30 minuti a 8 ore, o qualsiasi
durata a passi di 15 minuti fino a 24 ore, poi si spegne; se scegli una durata a Cocaine spento, si accende per quel tempo;
**Quando sei inattivo**: niente, abbassa o spegni lo schermo, e *Spegni ora*; **Protezione batteria**: a batteria, al 10–30 % spegne
Cocaine o ti avvisa soltanto; la scheda Cocaine con login, aggiornamenti, lingua, *Mostra nel notch*, feedback aptico e *App Comandi
Rapidi e link*; **Scorciatoie da tastiera**: attive di default, ⌃⌥⌘C attiva/spegne, ⌃⌥⌘O il pannello, ⌃⌥⌘P pausa avvisi, ⌃⌥⌘I
l'isola; clicca una scorciatoia e digita la nuova combinazione (Esc annulla, Elimina la toglie, *Ripristina predefinite*); non
servono permessi, una combinazione già usata da macOS o da un'altra app viene rifiutata o segnata *Usata da un'altra app*, e i nomi
seguono il layout della tastiera), *Avvisi AI* (gli agent al lavoro o gli ultimi
avvisi, poi le AI, quando e come), *Automazioni* (**Attivazione automatica**: attivo mentre un'AI lavora o aspetta te, mentre girano
i programmi scelti, con il caricatore o a batteria fino al livello della Protezione batteria, con un monitor esterno collegato o no,
o in una fascia oraria settimanale; vale "uno qualsiasi" o "tutti"; si spegne dopo un breve periodo di tolleranza; se lo spegni tu a
mano, vale la tua scelta; l'intestazione dice chi ha acceso Cocaine e un punto verde segna le condizioni vere adesso; poi *Resta
disponibile* e *Lavoro da remoto*) e, con l'isola attiva, *Isola* (*Sostituisci l'HUD di sistema* e le impostazioni degli appunti).
Gli elenchi si aprono come una scheda sotto la loro riga, dentro il pannello, mai come un menu sotto il notch.

**Schermo spento, Mac sveglio** (Generale → *Quando sei inattivo* → **Spegni**): dopo il tempo di inattività gli schermi si

spengono del tutto mentre il Mac continua a lavorare. Niente viene aggirato: il blocco segue *Impostazioni di Sistema → Schermata
di blocco* (in questa modalità lo schermo non è più tenuto acceso, quindi macOS può spegnerlo anche prima). Con il coperchio
chiuso e a batteria, se macOS segnala uno stato termico serio, Cocaine si spegne da solo. *Resta disponibile* si ferma mentre gli
schermi sono spenti, gli schermi AirPlay/Sidecar/DisplayLink possono ignorare lo spegnimento, e il comportamento con monitor
esterno e coperchio chiuso è documentato ma non è stato provato su hardware reale. Vedi
[Alimentazione e trigger](docs/power-and-triggers.it.md).

## Da sapere

- Mentre Cocaine è attivo il Mac **non si blocca da solo**, anche col coperchio chiuso: bloccalo con ⌃⌘Q.
- A batteria e col coperchio chiuso il Mac continua a consumare. Al 5 % Cocaine si spegne da solo per lasciare andare in stop
  il Mac, anche con la Protezione batteria spenta; impostala più in alto per fermarti prima.
- Quando apri l'app, Cocaine si attiva, e quando la chiudi rimette le cose com'erano. Vale per **Esci**, ⌘Q, la disconnessione, lo
  spegnimento, `kill` e i crash (un piccolo watchdog si accorge che Cocaine non c'è più). Se lo stop era già disattivato prima che
  Cocaine lo attivasse, o lo hai cambiato nel frattempo, viene rispettato; lo stesso se l'app viene eliminata mentre è aperta.
  Limiti: dopo un'interruzione di corrente o un riavvio forzato lo stop resta disattivato finché Cocaine non si riapre (o esegui
  `cocaine off`, o `Cocaine.app/Contents/MacOS/Cocaine --boot-check`); se Cocaine e il suo watchdog vengono terminati insieme,
  l'helper dello schermo rimette le cose a posto dopo un minuto. [Dettagli](docs/recovery.it.md).
- Permessi, ciascuno chiesto solo quando una funzione ne ha bisogno: **Accessibilità** (Resta disponibile, e i tasti di volume e
  luminosità con *Sostituisci l’HUD di sistema*), **Automazione** (Musica e Spotify; Terminale e iTerm2 per tornare alla scheda di
  una sessione), **Fotocamera** (Specchio), **Calendari** (Calendario), **File e cartelle** (Download e la cartella degli screenshot,
  per File). Ciò che manca compare in *Permessi* nel pannello con un pulsante *Consenti*.
- Domande, messaggi ed elenco di condivisione compaiono dentro il pannello o l'isola di Cocaine, con lo stesso design. Ciò che
  appartiene a macOS resta di macOS: la richiesta della password di amministratore, le domande sui permessi di privacy, le
  Impostazioni di Sistema e le finestre che AirDrop, Messaggi e Mail aprono dopo la scelta (Apple non permette di incorporarle).
- Gira una sola copia di Cocaine alla volta: riaprirlo mostra il pannello di quello già aperto.

## Disinstallazione

Con Homebrew: `brew uninstall --cask cocaine`. Chiude Cocaine (e lo termina se è bloccato), rimette lo stop e toglie l'app,
la regola sudo e gli hook degli Avvisi AI, senza chiedere nulla. (`--zap` cancella anche le impostazioni, la cronologia degli appunti e gli altri dati salvati.) Il passaggio di
disinstallazione del cask rispetta le regole di ripristino ([note](docs/maintainers/cask-changes.md)); Homebrew esegue quello della
versione installata, quindi il primo aggiornamento *alla* 2.3.0 usa ancora il precedente e il passaggio di consegne durante gli
aggiornamenti funziona dall'aggiornamento successivo.

Senza Homebrew: togli le spunte in Avvisi AI, *Scollega* gli strumenti in Contesto AI (MCP), esci da Cocaine (così si spegne), spostala nel Cestino, poi nel Terminale:

```
sudo rm /etc/sudoers.d/cocaine
```

## Come funziona

- `pmset -a disablesleep 1` impedisce lo stop, anche a coperchio chiuso. L'app installa una regola sudo che permette senza
  password solo `pmset -a disablesleep 1` e `0`, `pmset schedule wake`/`schedule cancel wake` marcati `cocaine` e la
  cancellazione della regola stessa.
- Mentre è attivo, `caffeinate -d` tiene acceso lo schermo (`-i` nella modalità schermo spento).
- La luminosità è gestita con le API DisplayServices di macOS.

Codice: l'app per la barra dei menu (Swift/SwiftUI) è in [`Sources/`](Sources), un file per area (vedi
[`Sources/README.md`](Sources/README.md)); `main.swift` è solo il punto d'ingresso (le opzioni da riga di comando e l'avvio).
`cocaine.zsh` è lo script "motore".
Per compilare: `./build.sh --no-install` (in `build.noindex/`; `./build.sh` senza opzioni la installa anche, come unica copia
sul Mac). `--sign local|developer-id|adhoc` sceglie il livello di firma e non ripiega mai su un altro; `--dmg` è una build di
release e richiede la chiave degli aggiornamenti ([dettagli](docs/signing-and-updates.it.md)). `./verify.sh` compila ed esegue
tutti i controlli automatici (i test dell'app girano da una copia con impostazioni proprie); lo stesso gira su GitHub Actions.

## Licenza

MIT: vedi [LICENSE](LICENSE).
