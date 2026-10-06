### Appunti (isola)

La pagina Appunti dell'isola tiene quello che copi: **testo** (il testo formattato diventa testo semplice), **immagini**
(salvate come PNG, con anteprima) e **file** (come riferimenti a dove si trovano, mai copie; un file spostato o eliminato
viene segnalato e non si può ricopiare). Clicca un elemento per rimetterlo negli appunti con il tipo giusto (testo,
immagine o i file stessi per il Finder): sale in cima e non viene registrato di nuovo. Copiare due volte la stessa cosa
non crea doppioni.

- **Cerca** filtra mentre scrivi (maiuscole e accenti indifferenti; testo, nomi e cartelle dei file, dimensioni delle
  immagini, app di provenienza).
- **Preferiti**: la stella tiene un elemento; i preferiti non contano nei limiti e non vengono mai tolti da questi. La
  stella nella barra mostra solo i preferiti.
- **Pausa** smette di registrare; quello che copi in pausa non viene tenuto, nemmeno dopo aver ripreso.
- **Eliminare**: un elemento (×, o clic destro), *Svuota cronologia* (tiene i preferiti) o *Elimina tutto* (anche
  preferiti, file salvati e la loro chiave nel Portachiavi).

**Mai tenuti**: i contenuti che i gestori di password e altre app segnano come nascosti, temporanei o generati
(marcatori di nspasteboard.org, quello di 1Password); quello che copi mentre in primo piano c'è un gestore di password
(1Password, Bitwarden, KeePassXC, LastPass, Dashlane, Enpass, Strongbox, NordPass, Proton Pass, Accesso Portachiavi,
Password); le app che escludi nelle Impostazioni; e, se non lo disattivi, il testo che sembra un numero di carta (con
cifra di controllo valida) o una chiave/un token (blocchi di chiavi private, JWT, prefissi noti di chiavi API, stringhe
lunghe e casuali). Puoi aggiungere espressioni regolari tue. Sono controlli euristici: prendono i casi comuni, non ogni
segreto.

**Solo in memoria, di base.** La cronologia sta in memoria e sparisce quando esci da Cocaine o spegni l'isola.
In Impostazioni → Isola → Appunti (la scheda Isola c’è quando l’isola è attiva) puoi attivare **Salva su questo Mac**: la cronologia viene allora tenuta in
`~/Library/Application Support/Cocaine/clipboard`, cifrata (AES-GCM) con una chiave casuale nel tuo Portachiavi di login
(solo questo Mac, mai sincronizzata), file leggibili solo da te. Se il Portachiavi non si può usare, non viene salvato
nulla e la pagina lo dice. Disattivandolo ti chiede se eliminare la copia salvata (con la sua chiave) o tenerla cifrata
per dopo. Niente esce mai dal Mac.

**Limiti** (Impostazioni): quanti elementi (25–500), per quanto tempo (da 1 ora a 30 giorni, o nessun limite), spazio
totale (10–250 MB) ed elemento più grande (1–25 MB). Si applicano mentre copi, al caricamento e circa una volta al minuto.

**Limiti della funzione**: gli appunti vengono controllati poco più di una volta al secondo; se l'app che copia non lo
dichiara, come provenienza si usa l'app in primo piano, quindi un'app che copia in background può essere attribuita a
un'altra. Con una build firmata ad hoc (senza identità di firma locale) macOS richiede di nuovo l'accesso al
Portachiavi dopo ogni aggiornamento; se lo rifiuti, non viene salvato nulla. Eliminare i file non garantisce che i byte
siano cancellati da un SSD: a rendere illeggibile la cronologia eliminata è il fatto che viene eliminata anche la sua
chiave. Il campo di ricerca prende la tastiera mentre la pagina Appunti è aperta.

**Se la cronologia salvata non si può leggere** (danneggiata, scritta con un'altra chiave o da una versione più recente), Cocaine sposta l'indice e le sue immagini insieme in una cartella `unreadable-<ora>` accanto, riparte vuota e non le cancella mai; se nemmeno questo riesce, non salva nulla. Se il Portachiavi rifiuta l'accesso all'avvio, il salvataggio si ferma solo per quell'avvio.
