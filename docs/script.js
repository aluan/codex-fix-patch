const header = document.querySelector('[data-header]');
const menuToggle = document.querySelector('[data-menu-toggle]');
const navigation = document.querySelector('[data-nav]');

const syncHeader = () => header?.classList.toggle('scrolled', window.scrollY > 20);
syncHeader();
window.addEventListener('scroll', syncHeader, { passive: true });

const closeMenu = () => {
  menuToggle?.setAttribute('aria-expanded', 'false');
  navigation?.classList.remove('open');
  document.body.classList.remove('menu-open');
};

menuToggle?.addEventListener('click', () => {
  const isOpen = menuToggle.getAttribute('aria-expanded') === 'true';
  menuToggle.setAttribute('aria-expanded', String(!isOpen));
  navigation?.classList.toggle('open', !isOpen);
  document.body.classList.toggle('menu-open', !isOpen);
});

navigation?.querySelectorAll('a').forEach((link) => link.addEventListener('click', closeMenu));
window.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') closeMenu();
});

const observer = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('visible');
    observer.unobserve(entry.target);
  });
}, { threshold: 0.12, rootMargin: '0px 0px -40px' });

document.querySelectorAll('.reveal-on-scroll').forEach((element) => observer.observe(element));

const providers = document.querySelectorAll('[data-provider]');
const providerName = document.querySelector('[data-provider-name]');
providers.forEach((provider) => {
  provider.addEventListener('click', () => {
    providers.forEach((item) => item.classList.remove('active'));
    provider.classList.add('active');
    if (providerName) providerName.textContent = provider.dataset.provider;
  });
});

const themePreview = document.querySelector('[data-theme-preview]');
const themeImage = document.querySelector('[data-theme-image]');
const themeTitle = document.querySelector('[data-theme-title]');
const themeOptions = document.querySelectorAll('.theme-option');

themeOptions.forEach((option) => {
  option.addEventListener('click', () => {
    if (option.classList.contains('active') || !themeImage) return;
    themeOptions.forEach((item) => item.classList.remove('active'));
    option.classList.add('active');
    themePreview?.classList.add('is-changing');

    const nextImage = new Image();
    nextImage.src = option.dataset.themeSrc;
    nextImage.addEventListener('load', () => {
      window.setTimeout(() => {
        themeImage.src = nextImage.src;
        themeImage.alt = option.dataset.themeAlt;
        if (themeTitle) themeTitle.textContent = option.dataset.themeName;
        themePreview?.classList.remove('is-changing');
      }, 140);
    }, { once: true });
  });
});

const year = document.querySelector('[data-year]');
if (year) year.textContent = new Date().getFullYear();
