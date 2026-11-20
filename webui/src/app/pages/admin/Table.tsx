// Shared table pieces: busy-aware action buttons, filter inputs, and the
// paged table with its empty state.
import type { ComponentChildren, JSX } from "preact";
import { pageWindow } from "./format.ts";
import {
  clearFilter,
  filterOf,
  filters,
  isBusy,
  PAGE_SIZES,
  pages,
  pageSize,
  setFilter,
  setPage,
  setPageSize,
} from "./store.ts";

type ButtonProps =
  & Omit<JSX.ButtonHTMLAttributes<HTMLButtonElement>, "class">
  & {
    /** Busy key: the button spins and is disabled while it is in flight. */
    busyKey: string;
    class?: string;
    children: ComponentChildren;
  };

/** A button bound to a busy key. */
export function ActionButton(
  { busyKey, class: cls, children, disabled, type, ...rest }: ButtonProps,
) {
  const on = isBusy(busyKey);
  const classes = [cls, on ? "busy" : ""].filter(Boolean).join(" ");
  return (
    <button
      {...rest}
      type={type ?? "button"}
      class={classes || undefined}
      disabled={on || Boolean(disabled)}
      aria-busy={on ? "true" : undefined}
    >
      {children}
    </button>
  );
}

/** Live filter for table `tableKey` (#filter-<key>); Escape clears it. */
export function FilterInput(
  { tableKey, placeholder }: { tableKey: string; placeholder: string },
) {
  const value = filters.value[tableKey] ?? "";
  return (
    <input
      type="search"
      class="filter-input"
      id={`filter-${tableKey}`}
      placeholder={placeholder}
      value={value}
      onInput={(ev) => setFilter(tableKey, ev.currentTarget.value)}
      onKeyDown={(ev) => {
        if (ev.key === "Escape" && ev.currentTarget.value) {
          ev.preventDefault();
          clearFilter(tableKey);
        }
      }}
    />
  );
}

/** A table cell with a class (e.g. "mono", "state-ok"). */
export interface StyledCell {
  readonly styled: true;
  text: string | number;
  cls: string;
}

export function styled(text: string | number, cls: string): StyledCell {
  return { styled: true, text, cls };
}

export function mono(text: string | number): StyledCell {
  return styled(text, "mono");
}

export type Cell = StyledCell | ComponentChildren;

export interface Row {
  /** Stable key, so rows keep their DOM (focus, audio) across refreshes. */
  key: string;
  cells: Cell[];
}

function isStyled(cell: Cell): cell is StyledCell {
  return typeof cell === "object" && cell !== null &&
    (cell as Partial<StyledCell>).styled === true;
}

function EmptyState(
  { tableKey, text }: { tableKey: string; text: string },
) {
  const q = filterOf(tableKey);
  if (!q) return <div class="empty">{text}</div>;
  return (
    <div class="empty">
      <span>No matches for “{q}”.</span>
      <button
        type="button"
        class="small"
        onClick={() => clearFilter(tableKey)}
      >
        Clear filter
      </button>
    </div>
  );
}

export interface TableProps {
  tableKey: string;
  headers: string[];
  rows: Row[];
  emptyText?: string;
}

/** A paged table; rows-per-page is shared and remembered. */
export function Table(
  { tableKey, headers, rows, emptyText = "Nothing here yet." }: TableProps,
) {
  if (!rows.length) return <EmptyState tableKey={tableKey} text={emptyText} />;
  const size = pageSize.value;
  const total = rows.length;
  const { page, totalPages, start, end } = pageWindow(
    total,
    size,
    pages.value[tableKey] ?? 1,
  );
  return (
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            {headers.map((h) => <th key={h} scope="col">{h}</th>)}
          </tr>
        </thead>
        <tbody>
          {rows.slice(start, end).map((row) => (
            <tr key={row.key}>
              {row.cells.map((cell, i) =>
                isStyled(cell)
                  ? <td key={i} class={cell.cls}>{String(cell.text)}</td>
                  : <td key={i}>{cell}</td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
      <div class="pager">
        <span class="muted">Showing {start + 1}–{end} of {total}</span>
        <div class="pager-controls">
          <label class="muted pager-size">
            Rows:
            <select
              aria-label="Rows per page"
              value={String(size)}
              onChange={(ev) =>
                setPageSize(
                  tableKey,
                  parseInt(ev.currentTarget.value, 10) || 25,
                )}
            >
              {PAGE_SIZES.map((sz) => (
                <option key={sz} value={String(sz)}>{sz}</option>
              ))}
            </select>
          </label>
          <button
            type="button"
            class="small"
            disabled={page <= 1}
            aria-label="Previous page"
            onClick={() => setPage(tableKey, page - 1)}
          >
            ‹ Prev
          </button>
          <span class="pager-info">Page {page} / {totalPages}</span>
          <button
            type="button"
            class="small"
            disabled={page >= totalPages}
            aria-label="Next page"
            onClick={() => setPage(tableKey, page + 1)}
          >
            Next ›
          </button>
        </div>
      </div>
    </div>
  );
}
