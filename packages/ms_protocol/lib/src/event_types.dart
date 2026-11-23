// Tipi di evento dell'hub (`HubEvent.type`). I client mostrano un tipo
// sconosciuto così com'è, quindi aggiungerne uno non rompe nessuno.

abstract final class EventType {
  // spazi e sessioni
  static const push = 'push';
  static const lock = 'lock';
  static const unlock = 'unlock';
  static const stale = 'stale';
  static const force = 'force';
  static const port = 'port';
  static const restore = 'restore';
  static const restoreFile = 'restore.file';
  static const generationDelete = 'generation.delete';
  static const spaceCreate = 'space.create';
  static const spaceUpdate = 'space.update';
  static const spaceDelete = 'space.delete';

  // hub
  static const gc = 'gc';
  static const gcError = 'gc.error';
  static const disk = 'disk';
  static const settings = 'settings';
  static const memberRole = 'member.role';
  static const ztnet = 'ztnet';
  static const telegramError = 'telegram.error';

  /// Tutti, nell'ordine sopra.
  static const all = [
    push,
    lock,
    unlock,
    stale,
    force,
    port,
    restore,
    restoreFile,
    generationDelete,
    spaceCreate,
    spaceUpdate,
    spaceDelete,
    gc,
    gcError,
    disk,
    settings,
    memberRole,
    ztnet,
    telegramError,
  ];
}
