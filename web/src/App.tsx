import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider } from 'wagmi';
import { BrowserRouter, NavLink, Route, Routes } from 'react-router-dom';
import { TREATY_ADDRESS } from './abi';
import { explorer, wagmiConfig } from './chain';
import { Wallet } from './components/Wallet';
import { Overview } from './pages/Overview';
import { Bind } from './pages/Bind';
import { Write } from './pages/Write';

const queryClient = new QueryClient();

/** Sidebar glyphs, one line stroke each, no icon library (GMX study.md macrostructure). */
const NavIcon = {
  book: (
    <svg viewBox="0 0 18 18" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.4">
      <path d="M3 3.5c1.6-.7 3.4-.7 5 0v11c-1.6-.7-3.4-.7-5 0z" />
      <path d="M13 3.5c-1.6-.7-3.4-.7-5 0v11c1.6-.7 3.4-.7 5 0z" />
    </svg>
  ),
  bind: (
    <svg viewBox="0 0 18 18" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.4">
      <path d="M9 3v12M3 9h12" strokeLinecap="round" />
    </svg>
  ),
  capacity: (
    <svg viewBox="0 0 18 18" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.4">
      <ellipse cx="9" cy="4.4" rx="5.5" ry="2" />
      <path d="M3.5 4.4v9.2c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2V4.4" />
      <path d="M3.5 9c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2" />
    </svg>
  ),
  contract: (
    <svg viewBox="0 0 18 18" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.4">
      <path d="M5 2.5h6l2.5 2.5v10.5h-9z" strokeLinejoin="round" />
      <path d="M7 8h4M7 11h4" strokeLinecap="round" />
      <path d="M11 2.5V5h2.5" strokeLinejoin="round" />
    </svg>
  ),
};

export function App() {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <BrowserRouter>
          <div className="shell">
            <div className="side">
              <NavLink to="/" className="brand">Heracles</NavLink>
              <nav aria-label="Sections">
                <NavLink to="/" end>{NavIcon.book}Weekend gaps</NavLink>
                <NavLink to="/bind">{NavIcon.bind}Price a layer</NavLink>
                <NavLink to="/write">{NavIcon.capacity}Write capacity</NavLink>
                <a className="ext" href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">{NavIcon.contract}Contract</a>
              </nav>
              <div className="netline">
                <span className="stamp">Arbitrum Sepolia · USDG</span>
              </div>
            </div>
            <div style={{ flex: '1 1 auto', minWidth: 0 }}>
              <div className="topbar">
                <Wallet />
              </div>
              <div className="content">
                <Routes>
                  <Route path="/" element={<Overview />} />
                  <Route path="/bind" element={<Bind />} />
                  <Route path="/write" element={<Write />} />
                </Routes>
                <footer className="foot">
                  <span>Heracles: excess-of-loss cover for the weekend gap, for the LP vaults of stock perp exchanges on Arbitrum.</span>
                  <a href={explorer.address(TREATY_ADDRESS)} target="_blank" rel="noreferrer">Treaty contract</a>
                </footer>
              </div>
            </div>
          </div>
        </BrowserRouter>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
