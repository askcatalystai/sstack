const cleanTitle = text => text.replace(/\s*\([SML][^)]*\).*$/, '').replace(/\s*\(.*?\)/g, '');
const node = (tag, className, text) => {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
};

