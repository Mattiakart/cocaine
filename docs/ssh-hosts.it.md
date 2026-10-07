### Host SSH: agenti AI su macchine remote

Impostazioni → AI → **Host SSH**. Claude Code, Codex, Gemini CLI, Qwen Code e la CLI di Cursor che girano su un server che
raggiungi con ssh compaiono in Cocaine come quelli locali: nell'elenco degli agenti (con il nome dell'host, ad es. *api · Dev box*),
negli avvisi (lampeggio, suono, voce, iPhone) e nella revisione di piani, domande e richieste di permesso nel notch — risposte dal
Mac, che tornano all'agente remoto. Si chiama "Host SSH" per non confonderlo con *Remote*, la funzione per iPhone.

**Come funziona.** Nessuna porta aperta, né sul Mac né sull'host, e nessun servizio là:

- Cocaine usa il tuo `/usr/bin/ssh` (quindi `~/.ssh/config`, ProxyJump, chiavi e agente ssh funzionano come nel Terminale), una
  connessione per host, con la chiave dell'host sempre verificata su `known_hosts` (mai `StrictHostKeyChecking=no`), nessuna
  richiesta di password (BatchMode), nessun inoltro di agente, X11 o porte anche se il config li chiede, e keepalive.
- Sull'host gira un piccolo **relay** (`~/.cocaine/bin/cocaine-relay`, uno script perl incluso in Cocaine.app; serve perl con
  JSON::PP e Digest::SHA, presenti di serie sulla maggior parte di Linux, macOS e BSD). Vive solo finché vive la connessione di
  Cocaine e parla col Mac solo attraverso quella connessione ssh, con righe firmate.
- Gli hook degli strumenti AI là eseguono il relay, che passa al Mac le loro notizie (e le richieste, aspettando la tua risposta).
  Se il Mac non è connesso, un hook non stampa nulla e lo strumento chiede nel suo terminale come sempre; là non si decide mai nulla.

**Aggiungere un host.** *Aggiungi host…* propone i nomi `Host` del tuo `~/.ssh/config` (e dei file che include) e di `known_hosts` —
solo letti, nulla viene collegato — oppure scrivi `utente@host` (con `:porta`). Poi, dopo il tuo OK, **Installa relay…** copia il
relay e una chiave in `~/.cocaine` là (0700; la chiave 0600) attraverso l'input di ssh (la chiave non compare mai in una riga di
comando). Poi **Esamina hook…** mostra, file per file, esattamente cosa cambierebbe nelle impostazioni degli strumenti AI là
(`~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json`, `~/.qwen/settings.json`, `~/.cursor/hooks.json`);
nulla viene scritto finché non premi **Modifica questi file**. Vengono aggiunte solo le voci di Cocaine (gli altri tuoi hook e
impostazioni restano come sono), ogni file viene sostituito solo se non è cambiato da quando è stato letto, resta una copia in
`~/.cocaine/backup`, e se un file non si può scrivere quelli già cambiati vengono ripristinati. Ripeterlo non cambia nulla. Codex
chiede una volta di fidarsi dei nuovi hook: esegui `/hooks` là. Le richieste di approvazione di Claude Code vengono aggiunte solo
se il relay ha potuto leggerne la versione (2.0.45 o successiva; piani e domande 2.1.78 o successiva).

**Connessioni.** Ogni host mostra un pallino e il suo stato: connesso (con gli strumenti che hanno gli hook), connessione in corso,
non raggiungibile (nuovo tentativo con un'attesa crescente da 2 secondi a 5 minuti, prima dopo il risveglio del Mac o un cambio di
rete), oppure fermo con il motivo:

- *La chiave dell'host è CAMBIATA* — Cocaine non si connette. Se te lo aspettavi, correggi `~/.ssh/known_hosts` nel Terminale, poi Riprova.
- *La chiave dell'host non è ancora nota* — connettiti una volta dal Terminale (`ssh <host>`) per verificarla e accettarla.
- *Accesso rifiutato* — chiavi, agente ssh o un accesso che richiede te (MFA, password): **Accedi nel Terminale** apre lì una
  connessione master (`ssh -M`, tenuta 8 ore); Cocaine poi si connette attraverso quella.
- *Niente perl*, *relay mancante*, *un'altra chiave* — installa di nuovo il relay.

Un relay più vecchio viene sostituito da solo con quello dell'app (la versione è controllata a ogni connessione). Mentre un host
non è raggiungibile le sue sessioni restano nell'elenco con la dicitura *host non raggiungibile* (fino a 6 ore) invece di sparire;
le novità avvenute nel frattempo (solo quale sessione è partita, finita o chiusa — mai alcun testo) restano sull'host e aggiornano
l'elenco quando la connessione torna. Ogni minuto si chiede al relay se il processo di ogni sessione remota è ancora vivo.

**Tornare a una sessione** su un host porta alla scheda di Terminale o iTerm2 che tiene la tua connessione ssh verso di esso
(trovata dal `SSH_CONNECTION` della sessione: il processo ssh locale con quella porta, poi il suo terminale), e seleziona il pannello
tmux là se gira in tmux. Se la scheda non si trova (un jump host, un NAT che cambia le porte, o ssh avviato da un'altra app come
Remote-SSH di VS Code), viene portata in primo piano un'app di terminale e Cocaine lo dice.

**Interruttori e rimozione.** L'interruttore principale della scheda chiude ogni connessione; ogni host ha il suo. *Rimuovi…* toglie
un host solo da Cocaine, oppure (se connesso) toglie anche gli hook di Cocaine e `~/.cocaine` da lì. Se l'host non è raggiungibile,
rimuovili a mano: `rm -rf ~/.cocaine` e le righe di Cocaine (segnate `# cocaine://alert`) nei file sopra.

**Sicurezza.**
- Ogni host ha una sua chiave casuale da 256 bit, nel tuo Portachiavi di login (solo questo Mac) e in `~/.cocaine/relay.key`
  sull'host. Ogni riga nei due sensi porta un HMAC-SHA256: le righe del Mac e del relay sono legate a una sfida nuova per ogni
  connessione e a numeri di sequenza crescenti (niente replay); ogni hook firma la propria richiesta e accetta solo una risposta firmata
  sul proprio id e nonce casuali. Tutto ciò che non è firmato, è malformato, ripetuto o troppo lungo viene rifiutato; i messaggi di
  benvenuto della shell remota vengono ignorati; un host che inonda viene limitato.
- I nomi degli host sono controllati (lettere, cifre e `. _ @ : -`, mai all'inizio `-`) e passati sempre a ssh come argomento a sé
  dopo `--`; i comandi eseguiti là sono stringhe fisse (nessun nome di host, percorso o testo tuo dentro).
- Ciò che Cocaine riceve da un host è trattato come l'input di un hook locale: limitato, ripulito, e concesso solo se la richiesta
  è stata mostrata per intero. Una sessione remota non indica mai nulla sul tuo Mac (nessuna cartella, processo o terminale del Mac).
- Un registro (*Registro*) annota quando gli host si sono connessi, cosa è stato installato o cambiato e il tipo di ogni richiesta e
  risposta — mai un comando, un piano, un messaggio o il contenuto di un file.
- L'account sull'host (e i suoi amministratori) può ovviamente vedere e falsificare ciò che gira là: Cocaine si fida di un host
  esattamente quanto ti fidi del tuo accesso ssh. Un Mac per account remoto: un secondo Mac che si connette prende il posto del relay.

**Non fatto / limiti.** I limiti del piano Claude da una statusline remota non vengono letti. Gli hook di Copilot, OpenCode e
Windsurf non vengono messi sugli host. Un host dove gira Cocaine stesso (un altro Mac) resta com'è. Le approvazioni remote sono
state provate da capo a fondo con un sostituto di ssh e il vero relay su questo Mac, non con un vero server remoto.
