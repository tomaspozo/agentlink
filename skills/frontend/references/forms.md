# Form Patterns -- React Hook Form + Zod

Form handling with React Hook Form for state management, Zod for validation, and a consistent modal pattern for create/edit forms. Covers schema definition, input registration, the FormField component, the standard form modal pattern, and centralized label maps.

## Contents
- Schema Definition
- Form Setup
- Input Registration
- FormField Component
- Form Modal Pattern
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
- Define `defaultValues` separately when the form needs initial state

### Default values

```typescript
const defaultValues: AnimalFormData = {
  tag_number: "",
  name: "",
  sex: "female",
  breed: "",
  birth_date: "",
  weight_kg: "",
  notes: "",
};
```

Always define default values for every field. React Hook Form uses them for `reset()` and to avoid uncontrolled-to-controlled warnings.

---

## Form Setup

```typescript
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";

const form = useForm<AnimalFormData>({
  resolver: zodResolver(animalSchema),
  defaultValues,
});

const {
  register,
  control,
  handleSubmit,
  formState: { errors },
  reset,
} = form;
```

Destructure what you need. The common set is:
- `register` -- for native HTML inputs
- `control` -- for controlled components (Select, Combobox, Checkbox)
- `handleSubmit` -- wraps the submit handler with validation
- `formState.errors` -- field-level error messages
- `reset` -- resets the form to default values

---

## Input Registration

### `register()` for native inputs

Use `register()` with standard HTML inputs (text, date, number, textarea). It returns `ref`, `onChange`, `onBlur`, and `name` props.

```typescript
<Input {...register("tag_number")} placeholder="001" />
<Input type="date" {...register("birth_date")} />
<Input type="number" step="0.1" {...register("weight_kg")} />
<Textarea {...register("notes")} rows={2} />
```

### `Controller` for controlled components

Use `Controller` for components that do not accept standard input props (like Radix-based Select, Combobox, Checkbox). These components use `value`/`onValueChange` or `checked`/`onCheckedChange` instead of `ref`/`onChange`.

```typescript
import { Controller } from "react-hook-form";

// Select
<Controller
  control={control}
  name="sex"
  render={({ field }) => (
    <Select value={field.value} onValueChange={field.onChange}>
      <SelectTrigger>
        <SelectValue placeholder="Select..." />
      </SelectTrigger>
      <SelectContent>
        <SelectGroup>
          <SelectItem value="female">Female</SelectItem>
          <SelectItem value="male">Male</SelectItem>
        </SelectGroup>
      </SelectContent>
    </Select>
  )}
/>

// Checkbox
<Controller
  control={control}
  name="alive"
  render={({ field }) => (
    <div className="flex items-center gap-2">
      <Checkbox
        id="alive"
        checked={field.value}
        onCheckedChange={(checked) => field.onChange(checked === true)}
      />
      <Label htmlFor="alive">Alive at birth</Label>
    </div>
  )}
/>

// Custom Combobox
<Controller
  control={control}
  name="damId"
  render={({ field }) => (
    <AnimalCombobox
      value={field.value}
      onValueChange={field.onChange}
      sex="female"
    />
  )}
/>
```

### When to use which

| Component | Method | Why |
|-----------|--------|-----|
| `<Input>` | `register()` | Native HTML input, accepts ref |
| `<Textarea>` | `register()` | Native HTML textarea, accepts ref |
| `<Select>` (Radix) | `Controller` | Uses `value`/`onValueChange`, not ref-based |
| `<Checkbox>` (Radix) | `Controller` | Uses `checked`/`onCheckedChange` |
| `<Combobox>` (custom) | `Controller` | Custom controlled component |

---

## FormField Component

The `FormField` component wraps every form field for consistent label and error display.

```typescript
// src/components/forms/form-field.tsx
import { Label } from "@/components/ui/label";

interface FormFieldProps {
  label: string;
  error?: string;
  children: React.ReactNode;
}

export function FormField({ label, error, children }: FormFieldProps) {
  return (
    <div data-invalid={error ? true : undefined}>
      <Label className="mb-1.5">{label}</Label>
      {children}
      {error && <p className="mt-1 text-xs text-destructive">{error}</p>}
    </div>
  );
}
```

### Usage

```typescript
import { FormField } from "@/components/forms/form-field";

// With register()
<FormField label="Tag Number *" error={errors.tag_number?.message}>
  <Input {...register("tag_number")} placeholder="001" />
</FormField>

// With Controller
<FormField label="Sex *" error={errors.sex?.message}>
  <Controller
    control={control}
    name="sex"
    render={({ field }) => (
      <Select value={field.value} onValueChange={field.onChange}>
        <SelectTrigger>
          <SelectValue placeholder="Select..." />
        </SelectTrigger>
        <SelectContent>
          <SelectGroup>
            <SelectItem value="female">Female</SelectItem>
            <SelectItem value="male">Male</SelectItem>
          </SelectGroup>
        </SelectContent>
      </Select>
    )}
  />
</FormField>

// Optional field (no asterisk, no error)
<FormField label="Notes">
  <Textarea {...register("notes")} rows={2} />
</FormField>
```

Key points:
- Mark required fields with `*` in the label text: `"Tag Number *"`
- Pass `errors.fieldName?.message` as the `error` prop -- it is `undefined` when there is no error
- The `data-invalid` attribute can be used for CSS styling on invalid fields

---

## Form Modal Pattern

The standard pattern for create and edit forms. State is managed by the parent via `open`/`onOpenChange` props, not internal to the modal.

```typescript
import { useForm, Controller } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod";
import { toast } from "sonner";
import { useCreateAnimal } from "@/mutations/animals";
import { FormField } from "@/components/forms/form-field";
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

const defaultValues: AnimalFormData = {
  tag_number: "",
  name: "",
  sex: "female",
  breed: "",
};

interface CreateAnimalModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

export function CreateAnimalModal({ open, onOpenChange }: CreateAnimalModalProps) {
  const createAnimal = useCreateAnimal();

  const form = useForm<AnimalFormData>({
    resolver: zodResolver(animalSchema),
    defaultValues,
  });

  const {
    register,
    control,
    handleSubmit,
    formState: { errors },
    reset,
  } = form;

  const handleClose = (isOpen: boolean) => {
    if (!isOpen) reset(defaultValues);
    onOpenChange(isOpen);
  };

  const onSubmit = (data: AnimalFormData) => {
    createAnimal.mutate(
      {
        tag_number: data.tag_number,
        sex: data.sex,
        name: data.name || null,
        breed: data.breed || null,
      },
      {
        onSuccess: () => {
          toast.success("Animal created");
          reset(defaultValues);
          onOpenChange(false);
        },
        onError: (err) => toast.error(err.message),
      },
    );
  };

  return (
    <Dialog open={open} onOpenChange={handleClose}>
      <DialogContent className="max-h-[90vh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Create Animal</DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit(onSubmit)} className="flex flex-col gap-3">
          <FormField label="Tag Number *" error={errors.tag_number?.message}>
            <Input {...register("tag_number")} placeholder="001" />
          </FormField>

          <FormField label="Sex *" error={errors.sex?.message}>
            <Controller
              control={control}
              name="sex"
              render={({ field }) => (
                <Select value={field.value} onValueChange={field.onChange}>
                  <SelectTrigger>
                    <SelectValue placeholder="Select..." />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectGroup>
                      <SelectItem value="female">Female</SelectItem>
                      <SelectItem value="male">Male</SelectItem>
                    </SelectGroup>
                  </SelectContent>
                </Select>
              )}
            />
          </FormField>

          <FormField label="Name">
            <Input {...register("name")} placeholder="Luna" />
          </FormField>

          <FormField label="Breed">
            <Input {...register("breed")} placeholder="Holstein" />
          </FormField>

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
- **`form.reset(defaultValues)` on close AND on success** -- prevents stale data when reopening
- **`handleClose` wraps `onOpenChange`** to always reset the form when the dialog closes (including backdrop click and escape key)
- **Mutation with toast feedback** -- `onSuccess` shows a success toast, `onError` shows the error message
- **Loading state on submit button** via `isPending` -- prevents double submission
- **`DialogContent` with `max-h-[90vh] overflow-y-auto`** -- ensures long forms scroll within the dialog on small screens
- **Form converts empty strings to `null`** -- `data.name || null` ensures empty optional fields are sent as `null` to the RPC, not as empty strings
- **`FormField` wraps every field** for consistent label and error layout

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

### Grid layouts in forms

Use CSS grid for side-by-side fields:

```typescript
<div className="grid grid-cols-2 gap-3">
  <FormField label="Date *" error={errors.date?.message}>
    <Input type="date" {...register("date")} />
  </FormField>
  <FormField label="Weight (kg)">
    <Input type="number" step="0.1" {...register("weight_kg")} />
  </FormField>
</div>
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
