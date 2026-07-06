# Form Patterns -- TanStack Form + Zod

Form handling with TanStack Form (`@tanstack/react-form`) for state management, Zod for validation, and shadcn's `Field`/`FieldGroup`/`FieldError` primitives for a consistent modal pattern for create/edit forms. Covers schema definition, `form.Field`'s render-prop pattern, the standard form modal pattern, and centralized label maps.

TanStack Form is used (not React Hook Form) because this scaffold is already TanStack Router + TanStack Query — same family, same mental model — and it's what shadcn's own forms documentation currently teaches.

## Contents
- Schema Definition
- Form Setup
- Field Types
- Form Modal Pattern
- Conditional Validation
- Centralized Label Maps

---

## Schema Definition

Every form starts with a Zod schema. The schema is the single source of truth for validation rules and the TypeScript type.

```typescript
import { z } from "zod";

const animalSchema = z.object({
  tag_number: z.string().min(1, "Tag number is required"),
  name: z.string().optional(),
  sex: z.enum(["male", "female"], { message: "Select a sex" }),
  breed: z.string().optional(),
  birth_date: z.string().optional(),
  weight_kg: z.string().optional(),
  notes: z.string().optional(),
});

type AnimalFormData = z.infer<typeof animalSchema>;
```

Key points:
- Required fields use `.min(1, "...")` for strings -- `.min(1)` is clearer than `.nonempty()`
- Optional fields use `.optional()` -- they can be `undefined` or an empty string
- Enums use `z.enum()` with a custom `message` for the error text
- Numeric inputs are defined as `z.string()` in the schema (HTML inputs return strings) and converted to numbers in the submit handler

---

## Form Setup

```typescript
import { useForm } from "@tanstack/react-form";

const form = useForm({
  defaultValues: {
    tag_number: "",
    name: "",
    sex: "female",
    breed: "",
  } as AnimalFormData,
  validators: { onSubmit: animalSchema },
  onSubmit: async ({ value }) => {
    // `value` is the validated, typed form data.
    await createAnimal.mutateAsync(value);
  },
});
```

```typescript
<form
  onSubmit={(e) => {
    e.preventDefault();
    e.stopPropagation();
    void form.handleSubmit();
  }}
>
  {/* ...fields... */}
</form>
```

Key points:
- `defaultValues` doubles as the reset target — always define one for every field, cast to the schema's inferred type when TanStack Form's inference doesn't line up (e.g. `as AnimalFormData`)
- `validators: { onSubmit: schema }` runs the whole Zod schema on submit — TanStack Form calls `onSubmit` (the mutation) only if validation passes
- The native `<form onSubmit>` always calls `e.preventDefault()` + `e.stopPropagation()` then hands off to `form.handleSubmit()` — this is boilerplate, copy it verbatim
- `form.reset(values?)` resets to `defaultValues`, or to `values` if provided (useful for seeding a form once async data — e.g. the record being edited — resolves)

---

## Field Types

Every field is authored with `form.Field`'s render-prop (`children`), wrapped in shadcn's `Field` component for label/error layout. Reference `field.state.value`/`field.handleChange`/`field.handleBlur` for the control, and `field.state.meta.isTouched`/`isValid`/`errors` for validation display.

### Input / Textarea

```typescript
import { Field, FieldError, FieldGroup, FieldLabel } from "@/components/ui/field";

<FieldGroup>
  <form.Field
    name="tag_number"
    children={(field) => {
      const isInvalid = field.state.meta.isTouched && !field.state.meta.isValid;
      return (
        <Field data-invalid={isInvalid}>
          <FieldLabel htmlFor={field.name}>Tag number</FieldLabel>
          <Input
            id={field.name}
            name={field.name}
            value={field.state.value}
            onBlur={field.handleBlur}
            onChange={(e) => field.handleChange(e.target.value)}
            aria-invalid={isInvalid}
            placeholder="001"
          />
          {isInvalid && <FieldError errors={field.state.meta.errors} />}
        </Field>
      );
    }}
  />
</FieldGroup>
```

`Textarea` follows the identical pattern — same props, swap `Input` for `Textarea`.

### Select

Base UI's `Select` requires an `items` array on the root (used for accessibility and the placeholder). Wire `value`/`onValueChange` straight to `field.state.value`/`field.handleChange` — no `Controller` needed, TanStack Form's fields are controlled natively. Base UI's `onValueChange` passes `T | null` (nullable, for a "cleared" selection); guard the null case before calling `field.handleChange` if the field itself is a non-nullable enum:

```typescript
const SEX_ITEMS = [
  { value: "female", label: "Female" },
  { value: "male", label: "Male" },
];

<form.Field
  name="sex"
  children={(field) => {
    const isInvalid = field.state.meta.isTouched && !field.state.meta.isValid;
    return (
      <Field data-invalid={isInvalid}>
        <FieldLabel htmlFor={field.name}>Sex</FieldLabel>
        <Select
          items={SEX_ITEMS}
          name={field.name}
          value={field.state.value}
          onValueChange={(value) => {
            if (value !== null) field.handleChange(value);
          }}
        >
          <SelectTrigger id={field.name} aria-invalid={isInvalid}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectGroup>
              <SelectItem value="female">Female</SelectItem>
              <SelectItem value="male">Male</SelectItem>
            </SelectGroup>
          </SelectContent>
        </Select>
        {isInvalid && <FieldError errors={field.state.meta.errors} />}
      </Field>
    );
  }}
/>
```

### Checkbox / Switch / RadioGroup

Same shape — `checked`/`onCheckedChange` (Checkbox, Switch) or `value`/`onValueChange` (RadioGroup) wired to `field.state.value`/`field.handleChange`:

```typescript
<form.Field
  name="alive"
  children={(field) => (
    <Field orientation="horizontal">
      <Checkbox
        id={field.name}
        checked={field.state.value}
        onCheckedChange={(checked) => field.handleChange(checked === true)}
      />
      <FieldLabel htmlFor={field.name} className="font-normal">
        Alive at birth
      </FieldLabel>
    </Field>
  )}
/>
```

### When to reach for `form.Subscribe`

Anything that needs to react to form-wide state (not a single field's value) — a submit button disabled until the form is dirty, a live field-value preview — goes through `form.Subscribe`, not a direct read of `form.state` (which isn't reactive outside a subscription):

```typescript
<form.Subscribe
  selector={(state) => state.isDirty}
  children={(isDirty) => (
    <Button type="submit" disabled={!isDirty || mutation.isPending}>
      {mutation.isPending ? "Saving…" : "Save changes"}
    </Button>
  )}
/>
```

---

## Form Modal Pattern

The standard pattern for create and edit forms. State is managed by the parent via `open`/`onOpenChange` props, not internal to the modal.

```typescript
import { useForm } from "@tanstack/react-form";
import { z } from "zod";
import { toast } from "sonner";
import { useCreateAnimal } from "@/mutations/animals";
import { Field, FieldError, FieldGroup, FieldLabel } from "@/components/ui/field";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Loader2 } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectGroup,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

const animalSchema = z.object({
  tag_number: z.string().min(1, "Tag number is required"),
  name: z.string(),
  sex: z.enum(["male", "female"], { message: "Select a sex" }),
  breed: z.string(),
});

type AnimalFormData = z.infer<typeof animalSchema>;

const SEX_ITEMS = [
  { value: "female", label: "Female" },
  { value: "male", label: "Male" },
];

interface CreateAnimalModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function CreateAnimalModal({ open, onOpenChange }: CreateAnimalModalProps) {
  const createAnimal = useCreateAnimal();

  const form = useForm({
    defaultValues: { tag_number: "", name: "", sex: "female", breed: "" } as AnimalFormData,
    validators: { onSubmit: animalSchema },
    onSubmit: async ({ value }) => {
      createAnimal.mutate(
        {
          tag_number: value.tag_number,
          sex: value.sex,
          name: value.name || null,
          breed: value.breed || null,
        },
        {
          onSuccess: () => {
            toast.success("Animal created");
            form.reset();
            onOpenChange(false);
          },
          onError: (err) => toast.error(err.message),
        },
      );
    },
  });

  const handleClose = (isOpen: boolean) => {
    if (!isOpen) form.reset();
    onOpenChange(isOpen);
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Create Animal</DialogTitle>
        </DialogHeader>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            e.stopPropagation();
            void form.handleSubmit();
          }}
        >
          <FieldGroup>
            <form.Field
              name="tag_number"
              children={(field) => {
                const isInvalid = field.state.meta.isTouched && !field.state.meta.isValid;
                return (
                  <Field data-invalid={isInvalid}>
                    <FieldLabel htmlFor={field.name}>Tag number</FieldLabel>
                    <Input
                      id={field.name}
                      name={field.name}
                      value={field.state.value}
                      onBlur={field.handleBlur}
                      onChange={(e) => field.handleChange(e.target.value)}
                      aria-invalid={isInvalid}
                      placeholder="001"
                    />
                    {isInvalid && <FieldError errors={field.state.meta.errors} />}
                  </Field>
                );
              }}
            />

            <form.Field
              name="sex"
              children={(field) => {
                const isInvalid = field.state.meta.isTouched && !field.state.meta.isValid;
                return (
                  <Field data-invalid={isInvalid}>
                    <FieldLabel htmlFor={field.name}>Sex</FieldLabel>
                    <Select
                      items={SEX_ITEMS}
                      name={field.name}
                      value={field.state.value}
                      onValueChange={(value) => {
                        if (value !== null) field.handleChange(value);
                      }}
                    >
                      <SelectTrigger id={field.name} aria-invalid={isInvalid}>
                        <SelectValue />
                      </SelectTrigger>
                      <SelectContent>
                        <SelectGroup>
                          <SelectItem value="female">Female</SelectItem>
                          <SelectItem value="male">Male</SelectItem>
                        </SelectGroup>
                      </SelectContent>
                    </Select>
                    {isInvalid && <FieldError errors={field.state.meta.errors} />}
                  </Field>
                );
              }}
            />

            <form.Field
              name="name"
              children={(field) => (
                <Field>
                  <FieldLabel htmlFor={field.name}>Name</FieldLabel>
                  <Input
                    id={field.name}
                    name={field.name}
                    value={field.state.value}
                    onBlur={field.handleBlur}
                    onChange={(e) => field.handleChange(e.target.value)}
                    placeholder="Luna"
                  />
                </Field>
              )}
            />

            <form.Field
              name="breed"
              children={(field) => (
                <Field>
                  <FieldLabel htmlFor={field.name}>Breed</FieldLabel>
                  <Input
                    id={field.name}
                    name={field.name}
                    value={field.state.value}
                    onBlur={field.handleBlur}
                    onChange={(e) => field.handleChange(e.target.value)}
                    placeholder="Holstein"
                  />
                </Field>
              )}
            />
          </FieldGroup>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => handleClose(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={createAnimal.isPending}>
              {createAnimal.isPending ? (
                <Loader2 data-icon="inline-start" className="animate-spin" />
              ) : null}
              Save
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
```

### Key points about this pattern

- **State managed by parent** via `open`/`onOpenChange` -- the modal does not own its visibility
- **`form.reset()` on close AND on success** -- prevents stale data when reopening
- **`handleClose` wraps `onOpenChange`** to always reset the form when the dialog closes (including backdrop click and escape key)
- **Mutation with toast feedback** -- `onSuccess` shows a success toast, `onError` shows the error message
- **Loading state on submit button** via `isPending` -- prevents double submission
- **`DialogContent` with `max-h-[90vh] overflow-y-auto`** -- ensures long forms scroll within the dialog on small screens
- **Form converts empty strings to `null`** -- `value.name || null` ensures empty optional fields are sent as `null` to the RPC, not as empty strings
- **`Field`/`FieldGroup` wrap every field** for consistent label, spacing, and error layout — never a raw `div` with manual `space-y-*`

### Usage in a page component

```typescript
function AnimalsPage() {
  const [showCreate, setShowCreate] = useState(false);

  return (
    <>
      <Button onClick={() => setShowCreate(true)}>
        <Plus data-icon="inline-start" /> New Animal
      </Button>

      <CreateAnimalModal open={showCreate} onOpenChange={setShowCreate} />
    </>
  );
}
```

### Seeding a form from async data

When a form edits an existing record that loads asynchronously (e.g. a workspace-settings page), seed it once the data resolves with `form.reset(values)` inside a `useEffect` — the same call used to reset to defaults, just given new values:

```typescript
const { reset } = form;
useEffect(() => {
  if (tenant) reset({ name: tenant.name, slug: tenant.slug });
}, [tenant, reset]);
```

Pre-filling a single field the same way (e.g. an email address arriving from an invitation preview) uses `form.setFieldValue` instead of a full reset, guarded so it only fires once:

```typescript
useEffect(() => {
  if (form.getFieldValue("email") === "" && invitedEmail) {
    form.setFieldValue("email", invitedEmail);
  }
  // eslint-disable-next-line react-hooks/exhaustive-deps
}, [invitedEmail]);
```

---

## Conditional Validation

When a field's requiredness depends on external component state (a mode toggle, a "show this field" flag) rather than another field's value, build the schema with `.superRefine()` reading that state via closure — **not** a ternary between two structurally different Zod objects. TanStack Form's `validators.onSubmit` type must stay consistent across renders; a ternary between e.g. `z.object({ password: z.string().optional() })` and `z.object({ password: z.string().min(6) })` produces a type TanStack Form can't reconcile.

```typescript
const [mode, setMode] = useState<"password" | "magic_link">("password");

const baseSchema = z.object({
  email: z.string().email("Enter a valid email"),
  password: z.string().optional(),
});

// Re-evaluated fresh every render, so toggling `mode` immediately swaps
// which rule is enforced — the inferred TS type never changes.
const schema = baseSchema.superRefine((data, ctx) => {
  if (mode === "password" && (!data.password || data.password.length < 6)) {
    ctx.addIssue({ code: "custom", path: ["password"], message: "At least 6 characters" });
  }
});

const form = useForm({
  defaultValues: { email: "", password: "" },
  validators: { onSubmit: schema },
  onSubmit: async ({ value }) => { /* ... */ },
});
```

For cross-field checks that depend only on other form values (not external state), a plain `.refine()` on the object works and needs no closure:

```typescript
const schema = z
  .object({
    password: z.string().min(6, "At least 6 characters"),
    confirm: z.string().min(6, "At least 6 characters"),
  })
  .refine((data) => data.password === data.confirm, {
    message: "Passwords don't match",
    path: ["confirm"],
  });
```

---

## Centralized Label Maps

Keep display text, badge variants, and other UI-mapping data in `src/config/labels.ts`. This avoids scattering translations and display logic across components.

```typescript
// src/config/labels.ts

// --- Status labels ---
export const statusLabels: Record<string, string> = {
  active: "Active",
  sold: "Sold",
  dead: "Deceased",
};

export const statusBadgeVariant: Record<string, "success" | "sky" | "bark"> = {
  active: "success",
  sold: "sky",
  dead: "bark",
};

// --- Severity labels ---
export const severityLabels: Record<string, string> = {
  critical: "Critical",
  high: "High",
  medium: "Medium",
  low: "Low",
};

export const severityBadgeVariant: Record<string, "destructive" | "warning" | "default"> = {
  critical: "destructive",
  high: "warning",
};

// --- Event type labels ---
export const fertilityEventLabels: Record<string, string> = {
  heat: "Heat detected",
  insemination: "Insemination",
  natural_mating: "Natural mating",
  pregnancy_check: "Pregnancy check",
  confirmed: "Pregnancy confirmed",
  negative: "Negative",
  abortion: "Abortion",
  calving: "Calving",
};

// --- Functions for complex variant logic ---
export function getFertilityBadgeVariant(eventType: string) {
  if (eventType === "calving") return "success" as const;
  if (eventType === "confirmed") return "secondary" as const;
  if (eventType === "insemination" || eventType === "natural_mating") return "sky" as const;
  if (eventType === "negative" || eventType === "abortion") return "destructive" as const;
  return "warning" as const;
}
```

### Usage in components

```typescript
import { statusLabels, statusBadgeVariant } from "@/config/labels";

<Badge variant={statusBadgeVariant[animal.status] ?? "success"}>
  {statusLabels[animal.status] ?? animal.status}
</Badge>
```

### Rules

- **One file for all label maps** -- `src/config/labels.ts`
- **Record-based maps** for simple key-value lookups (labels, badge variants)
- **Functions** for complex variant logic (multiple conditions, fallbacks)
- **Always provide a fallback** in the component: `statusLabels[status] ?? status` -- handles unknown values gracefully
- **Keep display text out of components** -- components import from labels, never hardcode display strings
- **Single source of truth** -- if a label needs to change, update it in one place
