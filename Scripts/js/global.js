import {SetupKeyboardActions} from './utils/keyboard-actions.js';
import {ResetBodyMargin} from './utils/reset-body-margin.js';

if (! window.__JS_Global_isLoaded) {
    window.__JS_Global_isLoaded = true;
    SetupKeyboardActions();
    ResetBodyMargin();
}
