# Le schermate dell'isola

Impostazioni → **Isola** → **Schermate** organizza le pagine dell'isola ("schermate") e cosa contiene ciascuna.

## Cosa puoi cambiare

- **Mostra o nascondi** una schermata con il suo interruttore. Una schermata nascosta esce dalla barra delle schede, dai tasti ←/→ e
  dall'elenco di VoiceOver. Almeno una schermata resta sempre visibile (il suo interruttore è disattivato). La schermata **Monitor**
  compare solo con un monitor esterno DDC/CI collegato, ovunque tu la metta.
- **Ordine**: trascina una riga dalla maniglia, o usa i pulsanti ↑/↓ (anche azioni VoiceOver *Sposta su* / *Sposta giù*). La prima
  schermata visibile è la cella in cui si trasforma la busta all'apertura; se non è Home, la busta si fonde nella sua icona.
- **Schermata iniziale**: *Ultima usata* (predefinita: come prima, la prima schermata dopo l'avvio) oppure una schermata precisa,
  su cui l'isola si apre ogni volta (impostata dopo la chiusura, così chiudendo non salta). Se è nascosta vale l'ultima usata.
- **Moduli**: apri i moduli di una schermata con il suo pulsante ☰. Ogni modulo ha una colonna (*Sinistra* / *Destra*) e una
  dimensione: **S** un terzo dell'altezza della colonna, **M** metà, **L** tutta; un modulo con una sola dimensione dice *Riempie la
  colonna*. *Aggiungi modulo* aggiunge un modulo di qualsiasi pagina (una volta per schermata); *Unisci a* sposta tutti i moduli di
  una schermata in un'altra e la nasconde.
- **Anteprima**: una miniatura dell'isola aperta con le tue schede e i moduli della schermata modificata dove l'isola li disegna.
- **Ripristina predefinite** (con conferma) torna alla disposizione originale e dimentica quella salvata.

## La dimensione fissa

La pagina dell'isola ha la misura scelta in Impostazioni → Isola → Notch (640 × 214 di default; il contenuto cresce con
un'isola più grande, vedi docs/notch-animations.it.md). Due colonne sono 250 pt (di più in un'isola più grande, in proporzione) e il resto (la colonna larga va al modulo che ne ha bisogno, altrimenti a quella con
il modulo più grande; a parità a destra, come nelle pagine originali); una colonna sola prende tutta la larghezza. Se i moduli di
una colonna non ci stanno, il più basso che può rimpicciolirsi si rimpicciolisce, altrimenti il più basso resta fuori; un modulo che
occupa tutta la schermata (Calendario, Focus, Multimedia, Specchio, Monitor) lascia fuori l'altra colonna; due moduli che chiedono la
colonna larga (Musica, Scaffale) non stanno affiancati. La scheda dice quale modulo è stato rimpicciolito o lasciato fuori e perché
(⚠ sulla riga); niente viene mai disegnato tagliato. La tabella dei moduli è in [screens.en.md](screens.en.md).

## Salvataggio e verifiche

`screens.v1` nelle impostazioni di Cocaine (JSON con versione). Niente salvato, un valore illeggibile o scritto da un Cocaine più
nuovo valgono la disposizione originale, che disegna ogni pagina esattamente come prima. `Cocaine --screens-test` (anche in
`--selftest`) verifica le regole; i render usano `--screens-fixture <nome>` e `--screens-edit <schermata>`.
