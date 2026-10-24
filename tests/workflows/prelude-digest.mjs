// Loads digestOf from the checkpoint module, so a test signs a state the way the workflows do.
import { loadModule } from '../../claude/workflow-prelude/load.mjs'

export const { digestOf } = loadModule('checkpoint')
