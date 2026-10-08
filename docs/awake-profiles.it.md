# Profili per tenere sveglio il Mac, dischi tenuti svegli, statistiche

Ciò che Cocaine ha preso da Amphetamine (i suoi "Trigger", "Drive Alive", i promemoria di sessione e le statistiche) e come funziona
qui. Vedi anche [Tenere sveglio il Mac](keep-awake.it.md), [Alimentazione e trigger](power-and-triggers.it.md) e [Script](scripting.it.md).

## Profili (Automazione → Profili)

Un profilo è un insieme di **condizioni** con un nome. Finché sono vere, il profilo tiene sveglio il Mac da solo (oppure, se lo scegli,
ferma tutti i trigger così il Mac può dormire). I profili affiancano gli Smart Trigger: la scheda Smart Trigger non cambia e funziona
come prima; un profilo è semplicemente un motivo in più per tenere sveglio il Mac.

**Nuovo profilo → Aggiungi…** parte da zero o da uno pronto: *In ufficio* (una rete Wi-Fi + il caricabatterie), *Alla scrivania* (un
monitor esterno + il caricabatterie), *Presentazione* (duplicazione schermo o Keynote in primo piano), *Disco di backup* (un disco
collegato, gli schermi possono spegnersi), *Download grandi*, *Batteria scarica* (a batteria sotto il 20 %: lascia dormire il Mac).
**Modifica** lo apre sotto la sua riga; l'interruttore lo attiva o disattiva.

### Condizioni

| Condizione | Cosa legge | Permesso |
|---|---|---|
| Rete Wi-Fi | il nome della rete (CoreWLAN), esatto, maiuscole indifferenti | **Servizi di localizzazione** (da macOS 14 il nome non viene dato a nessuna app senza; la riga ha un pulsante *Consenti*, chiesto solo quando un profilo lo usa). La tua posizione non viene mai letta |
| Wi-Fi connesso | l'interfaccia Wi-Fi è attiva con un indirizzo IPv4 instradabile | nessuno |
| Ethernet connesso | un'interfaccia che macOS elenca come Ethernet (adattatori, porte integrate; anche un iPhone via USB) attiva con un IPv4 instradabile | nessuno |
| Hotspot personale | il percorso del framework Network è "costoso" (l'hotspot di un iPhone, o un'altra rete che macOS considera a consumo) | nessuno |
| Internet raggiungibile | il percorso del framework Network è soddisfatto (nessun traffico inviato) | nessuno |
| Indirizzo IP | uno degli indirizzi del Mac: intero (`192.168.1.20`), un inizio (`192.168.1.`) o un intervallo (`192.168.1.0/24`); IPv6 intero o per inizio | nessuno |
| Server DNS | i server DNS del sistema (stesse forme) | nessuno |
| Una VPN è connessa | come lo Smart Trigger: un'interfaccia tunnel con un indirizzo instradabile | nessuno |
| Un dispositivo USB è collegato | i nomi dei prodotti USB di IOKit, basta una parte del nome | nessuno |
| Un dispositivo Bluetooth è connesso | l'elenco *connessi* di `system_profiler SPBluetoothDataType`, al massimo ogni 20 s, in background | nessuno (IOBluetooth richiederebbe il permesso Bluetooth; system_profiler no) |
| Il suono esce da | il nome dell'uscita predefinita contiene uno di quelli scelti | nessuno |
| Un disco è collegato | uno dei volumi scelti è montato | nessuno |
| Processore | sopra o sotto il 10/25/50/75 % per 1/2/5/10 minuti senza interruzioni (ogni condizione ha il suo conteggio) | nessuno |
| App in primo piano | l'app in primo piano per nome o bundle id (Cocaine stesso è ignorato) | nessuno |
| App aperta | un programma in esecuzione per nome | nessuno |
| Inattività | meno di, o almeno, 1/5/10/30/60 minuti dall'ultimo input (gli eventi di "Non mostrarmi assente" non contano) | nessuno |
| Download in corso | un file parziale di un browser in Download, o un file lì che cresce | File e cartelle → Download (illeggibile: mai vera) |
| Sul caricabatterie | la fonte di alimentazione | nessuno |
| Livello batteria | almeno, o sotto, il 10/20/30/50/80 % | nessuno |
| Monitor esterno | ne è collegato uno (anche in stop) | nessuno |
| Duplicazione schermo | un monitor è in un gruppo di duplicazione | nessuno |
| Programma | giorni e un'ora di inizio/fine (oltre la mezzanotte come negli Smart Trigger) | nessuno |

Ogni condizione tranne Processore, Inattività e Livello batteria si può invertire con **È / Non è**. Una lettura che non si può fare (il
nome Wi-Fi senza Servizi di localizzazione, il Bluetooth prima della prima lettura, la cartella Download illeggibile, nessuna batteria)
**non è mai vera, nemmeno con "Non è"**: un dato sconosciuto non tiene mai sveglio il Mac per sbaglio. Una condizione a elenco senza
nulla scelto non è mai vera, nemmeno con "Non è" (la riga dice *Scegline almeno uno*). *Scrivi un nome…* in ogni elenco aggiunge un nome che ora non c'è (una
rete a cui non sei collegato, un dispositivo spento).

Si legge solo ciò che usano i profili attivi, ogni 5 secondi insieme agli Smart Trigger: niente lettura Bluetooth, nome Wi-Fi o
cartella Download se nessun profilo li chiede.

### Impostazioni di un profilo

- **Si attiva quando**: *Tutte vere* (predefinito) o *Una qualsiasi*.
- **Poi**: *Tieni sveglio*, oppure *Lascia dormire il Mac* (finché è vero, nessuno Smart Trigger e nessun profilo sotto di lui accende
  Cocaine; un'accensione fatta da un trigger finisce; un'accensione fatta a mano non viene mai toccata).
- **Gli schermi possono spegnersi** (solo Tieni sveglio): mentre decide questo profilo, il motore tiene sveglio il Mac ma non gli schermi
  (`caffeinate -i` invece di `-d`, lo stesso della modalità *Spegni schermo*), quindi gli schermi si spengono e si bloccano come
  impostato in macOS. *Non mostrarmi assente*, se attivo, tiene comunque accesi gli schermi.
- **Parti dopo** (subito / 10 s / 30 s / 1 min / 5 min) e **Fermati dopo** (subito / 30 s / 1 / 5 / 15 min): le condizioni devono
  essere vere, o smettere di esserlo, per quel tempo **senza interruzioni**. È l'isteresi: un Wi-Fi che cade per qualche secondo o una
  lettura CPU ballerina non fanno mai scattare il profilo (provato: un'alternanza ogni 5 s per due minuti non cambia nulla). Una lettura
  del processore fatta meno di 2 s dopo la precedente (i trigger vengono riletti anche quando cambia un'impostazione o si monta un
  disco) non conta come campione. Se l'orologio viene spostato indietro, ogni attesa riparte dalla nuova ora invece di aspettare la vecchia.
- **Al massimo** (nessun limite / 30 min … 8 h): il tempo massimo che il profilo tiene sveglio il Mac di fila; poi si ferma e aspetta
  che le condizioni cessino prima di poter ripartire.
- **Avvisi**: un breve avviso (isola, o VoiceOver) quando parte e quando finisce.
- **Priorità**: l'ordine della lista (↑ ↓). **Decide il primo profilo le cui condizioni sono vere**: se il Mac resta sveglio o tutti i
  trigger aspettano, e se gli schermi possono spegnersi. Gli altri sotto aspettano; la riga dice *Attivo (decide un profilo più in alto)*.

Come si combina col resto: Cocaine si accende quando uno Smart Trigger (Una/Tutte, come prima) **o** il profilo che decide lo vuole; si
spegne quando nessuno dei due lo vuole: dopo il periodo di tolleranza dei trigger, o subito se solo un profilo lo teneva acceso (il
profilo ha già aspettato il suo *Fermati dopo*). Protezione batteria, la soglia del 5 %, la protezione dal calore e *Pausa a schermo
bloccato* fermano i profili esattamente come i trigger. Se spegni Cocaine tu, la scelta è rispettata finché i motivi non cessano, come
coi trigger. "Acceso da …" nomina il profilo.

### Dall'esterno

- **Link** (Comandi Rapidi → *Apri URL*): `cocaine://profile?name=Ufficio&enabled=0` (o `1`, `on`/`off`, `true`/`false`); con
  x-callback-url risponde con lo stato, `x-error` riceve `no such profile`. Protetto come ogni link che cambia qualcosa.
- **AppleScript**: `enable profile "Ufficio"`, `disable profile "Ufficio"` (rispondono se ora è attivo; un nome sconosciuto è un
  errore), `get active profile` (quello che decide, o testo vuoto), `get profile names`.
- **Riga di comando**: `cocaine profiles` (stato, nome, condizioni; `--json`), `cocaine profiles enable|disable <nome>` (tramite il link
  protetto: Cocaine può chiedere prima). La lettura non scrive nulla.

## Tieni svegli i dischi (Automazione → Tieni svegli i dischi)

Per i dischi esterni che si fermano troppo presto (e i volumi NAS che parcheggiano i dischi): scegli i volumi in **Dischi** (l'elenco
nasce da ciò che è montato ora; il disco di avvio non è proposto), l'intervallo (**Ogni** 30 s / 1 / 2 / 5 / 10 min) e **Quando**
(*Mentre Cocaine è attivo*, predefinito, o *Sempre*). Ogni volume scelto viene toccato solo mentre è montato; la riga dice quando è stato
toccato l'ultima volta, o perché no.

**Metodo**, onestamente:

- **Piccolo file nascosto** (predefinito; quello che funziona davvero): Cocaine riscrive un suo file da 64 byte nella cartella principale
  del volume, `.cocaine-drive-alive` (nascosto, escluso da Time Machine), con `F_NOCACHE` e `F_FULLFSYNC` perché la scrittura arrivi
  davvero al disco invece di restare in memoria. Sempre lo stesso file e la stessa dimensione: non si accumula nulla. Viene aperto con
  `O_NOFOLLOW` e solo se è un piccolo file normale con un solo collegamento: un link o un file di qualcun altro con quel nome non viene
  toccato (la riga lo dice). Togliere un disco dalla lista elimina il file (se il disco è montato), e così passare a *Sola lettura* e disinstallare
  Cocaine (sui dischi scelti montati in quel momento). Un volume di sola lettura non può
  usare questo metodo.
- **Sola lettura**: non viene mai scritto nulla. Cocaine legge 4 KB con `F_NOCACHE` (lettura anticipata disattivata) da un punto
  diverso del file visibile più grande vicino alla cima del volume (la cartella principale e un livello sotto). **Al meglio delle
  possibilità**: se macOS ha già in memoria quel pezzo, il disco non viene toccato, quindi su un volume di file piccoli può non bastare a
  tenerlo in rotazione. Alcuni file system registrano l'ora di accesso.

Ogni tocco apre e chiude subito il file (l'espulsione non è mai bloccata), non avviene mai mentre macOS smonta quel volume (un minuto di
pausa) e gira fuori dal thread principale, uno alla volta per volume; anche l'elenco dei volumi montati si legge fuori dal thread
principale (un volume di rete che non risponde più non blocca mai l'app). Limiti: alcuni box USB hanno un proprio timer di stop nel firmware
che può ignorare questa attività; un disco fermo perché il Mac dormiva si risveglia col Mac; macOS può chiedere una volta se Cocaine può
usare i file su un volume rimovibile o di rete (Privacy e sicurezza → File e cartelle). `cocaine disks` elenca i dischi scelti e se
ognuno è montato.

## Promemoria e statistiche (Generale → Tenere sveglio)

- **Ricordamelo mentre è attivo**: Mai / 1 / 2 / 4 / 8 h: un avviso dice da quanto Cocaine è attivo, una volta per intervallo di sessione.
- **Statistiche**: sessioni, tempo di veglia totale e da quando, con **Azzera**. Una sessione lasciata aperta da un'uscita o un crash
  conta solo fino all'ultima volta che Cocaine l'ha vista attiva (salvato ogni minuto).

## Test e cosa è stato verificato

`Cocaine --triggers-test` (parte di `./verify.sh`) controlla le condizioni su istantanee fisse, il meccanismo di avvio/arresto (anche
con letture ballerine), la priorità e "lascia dormire il Mac", i limiti di salvataggio e la lettura tollerante, il link, i comandi
AppleScript (su un consenso finto) e il dizionario, la riga di comando su impostazioni in memoria, il parser Bluetooth, la
pianificazione dei dischi, le vere operazioni su file di entrambi i metodi in una cartella temporanea (link, hard link, file grandi e
cartelle non scrivibili rifiutati), statistiche e promemoria, e una lettura in sola lettura della rete, dei monitor e dell'elenco
Bluetooth di questo Mac (stampa solo dei conteggi).

**Non verificato dal vivo qui**: un vero disco esterno a piatti (nessuno collegato), la richiesta dei Servizi di localizzazione e il
nome Wi-Fi con il permesso concesso, un hotspot personale, e dispositivi Bluetooth che si collegano e scollegano mentre un profilo è
attivo (il parser è stato provato sull'output reale di `system_profiler` di questo Mac). Anteprime:
`--render-panel out.png --auto triggers --triggers [--edit-profile]`.
