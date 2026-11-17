//  Pressing `Ctrl-A` select the closest `div` anchestor.
//      The `div` need to have `tabindex="0"` attribute set, so it is focusable.
export function SetupKeyboardActions() {
    function GetDeepActElem() {
        let activeElement = document.activeElement;
        while (activeElement?.shadowRoot?.activeElement)
            activeElement = activeElement.shadowRoot.activeElement;
        return activeElement;
    }

    document.addEventListener('keydown', function(event) {
        if ((event.key === 'a') && (event.ctrlKey || event.metaKey)) {
            const fcsdElement = GetDeepActElem();                               //  Find the element that currently has focus.
            switch (fcsdElement?.tagName) {
              case undefined:
              case null:
              case 'INPUT':
              case 'TEXTAREA':
                break;
              default:
                const closestParentDiv = fcsdElement.closest('div');            //  Find the closest ancestor `div` to the focused element.
                if (closestParentDiv) {                                         //  If a div was found, select its contents.
                    event.preventDefault();                                     //  Prevent the default browser action (selecting everything).
                    const selection = document.getSelection();
                    selection.removeAllRanges();                                //  Clear any previous selection.
                    selection.selectAllChildren(closestParentDiv);              //  Select all children.
                }
            }
        }
    });
}
